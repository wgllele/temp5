// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.28;

/// @title 波场跨到以太坊后的 Curve 收款模板
/// @notice 资产打到本 clone 后再 swap。部署前把 `FACTORY` / `IMPLEMENTATION` 写成真实地址。
/// @dev 权限：`salt = keccak256(abi.encode(recipient))`。工厂和实现地址已在 CREATE2 的 deployer / init code 里，不再放进 salt。
///      `address(this)` 必须等于 `CREATE2(FACTORY, salt, EIP-1167(IMPLEMENTATION))`。
///      `swap` / `bridgeBack` 仅用户本人，不收 gas。`swapWithSig` / `bridgeBackWithSig` 验 EIP-712（含 gasFee），费打给工厂 `feeRecipient`。
///      退回只发 USDT：`to` 是去掉 `0x41` 的波场 20 字节，`msg.value` 为 LayerZero nativeFee。
contract CrossChainCurveReceiver {
    event Swap(
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event GasFeeCharged(address indexed token, address indexed feeRecipient, uint256 gasFee);
    event BridgeBack(address indexed sender, address indexed recipient, address indexed to, uint256 amount, uint256 minAmountLD);

    error ZeroAddress();
    error UnauthorizedInstance();
    error NotRecipient();
    error UnknownToken();
    error UnknownPool();
    error SameToken();
    error ZeroAmount();
    error Slippage(uint256 amountOut, uint256 minAmountOut);
    error Expired();
    error InvalidSignature();
    error GasFeeExceedsOut(uint256 gasFee, uint256 amountOut);
    error Reentrancy();

    address public constant FACTORY = 0x0000000000000000000000000000000000000000;
    address public constant IMPLEMENTATION = 0x0000000000000000000000000000000000000000;

    address private constant POOL_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address private constant POOL_USDC_USDT = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
    address private constant POOL_PYUSD_USDC = 0x383E6b4437b59fff47B619CBA855CA29342A8559;
    address private constant POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address private constant POOL_USDC_RLUSD = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @dev 以太坊 UsdtOFT。波场 peer `0x3a08F76772e200653bB55c2a92998DAcA62e0e97`。
    address private constant USDT_OFT = 0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0;
    uint32 private constant LZ_EID_TRON = 30420;
    address private constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address private constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address private constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    bytes32 private constant SWAP_TYPEHASH = keccak256(
        "Swap(address recipient,uint256 swapType,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 gasFee,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant BRIDGE_TYPEHASH = keccak256(
        "BridgeBack(address recipient,address to,uint256 amount,uint256 minAmountLD,uint256 gasFee,uint256 nonce,uint256 deadline)"
    );

    uint256 private _status;
    mapping(address => uint256) public nonces;

    constructor() {
        _status = 1;
    }

    /// @notice 用户本人兑换。不收 gas、不验签名。
    function swap(
        address recipient,
        uint256 swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        if (_status == 2) revert Reentrancy();
        _status = 2;
        if (msg.sender != recipient) revert NotRecipient();
        if (!_ok(recipient)) revert UnauthorizedInstance();
        amountOut = _curve(swapType, tokenIn, tokenOut, amountIn, minAmountOut);
        _send(tokenOut, recipient, amountOut);
        emit Swap(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
        _status = 1;
    }

    /// @notice 代操作。签名覆盖 `gasFee`（tokenOut 数量），费打给工厂 `feeRecipient`。
    function swapWithSig(
        address recipient,
        uint256 swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 gasFee,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountOut) {
        if (_status == 2) revert Reentrancy();
        _status = 2;
        if (block.timestamp > deadline) revert Expired();
        if (!_ok(recipient)) revert UnauthorizedInstance();
        uint256 nonce = nonces[recipient]++;
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256("CrossChainCurveReceiver"),
                        keccak256("1"),
                        block.chainid,
                        address(this)
                    )
                ),
                keccak256(
                    abi.encode(
                        SWAP_TYPEHASH, recipient, swapType, tokenIn, tokenOut, amountIn, minAmountOut, gasFee, nonce, deadline
                    )
                )
            )
        );
        if (ecrecover(digest, v, r, s) != recipient) revert InvalidSignature();

        amountOut = _curve(swapType, tokenIn, tokenOut, amountIn, minAmountOut);
        if (gasFee > amountOut) revert GasFeeExceedsOut(gasFee, amountOut);
        if (gasFee != 0) {
            (bool ok, bytes memory data) = FACTORY.staticcall(abi.encodeWithSignature("feeRecipient()"));
            if (!ok || data.length < 32 || abi.decode(data, (address)) == address(0)) revert ZeroAddress();
            _send(tokenOut, abi.decode(data, (address)), gasFee);
            emit GasFeeCharged(tokenOut, abi.decode(data, (address)), gasFee);
        }
        if (amountOut != gasFee) _send(tokenOut, recipient, amountOut - gasFee);
        emit Swap(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
        _status = 1;
    }

    /// @notice 用户本人提走本合约上的代币。不收 gas。
    function withdraw(address token, uint256 amount, address recipient) external {
        if (_status == 2) revert Reentrancy();
        _status = 2;
        if (msg.sender != recipient) revert NotRecipient();
        if (!_ok(recipient)) revert UnauthorizedInstance();
        if (amount == 0) revert ZeroAmount();
        _send(token, recipient, amount);
        _status = 1;
    }

    /// @notice 用户本人把本合约 USDT 退回波场。不收 gas。`msg.value` 整笔记给 UsdtOFT。
    function bridgeBack(address recipient, address to, uint256 amount, uint256 minAmountLD) external payable {
        if (_status == 2) revert Reentrancy();
        _status = 2;
        if (msg.sender != recipient) revert NotRecipient();
        if (!_ok(recipient)) revert UnauthorizedInstance();
        _oft(to, amount, minAmountLD);
        emit BridgeBack(msg.sender, recipient, to, amount, minAmountLD);
        _status = 1;
    }

    /// @notice 代操作退回波场。`gasFee` 从 `amount` 里扣 USDT 打给工厂 `feeRecipient`，其余再 `send`。
    function bridgeBackWithSig(
        address recipient,
        address to,
        uint256 amount,
        uint256 minAmountLD,
        uint256 gasFee,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable {
        if (_status == 2) revert Reentrancy();
        _status = 2;
        if (block.timestamp > deadline) revert Expired();
        if (!_ok(recipient)) revert UnauthorizedInstance();
        if (gasFee > amount) revert GasFeeExceedsOut(gasFee, amount);
        uint256 nonce = nonces[recipient]++;
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256("CrossChainCurveReceiver"),
                        keccak256("1"),
                        block.chainid,
                        address(this)
                    )
                ),
                keccak256(abi.encode(BRIDGE_TYPEHASH, recipient, to, amount, minAmountLD, gasFee, nonce, deadline))
            )
        );
        if (ecrecover(digest, v, r, s) != recipient) revert InvalidSignature();
        if (gasFee != 0) {
            (bool ok, bytes memory data) = FACTORY.staticcall(abi.encodeWithSignature("feeRecipient()"));
            if (!ok || data.length < 32 || abi.decode(data, (address)) == address(0)) revert ZeroAddress();
            _send(USDT, abi.decode(data, (address)), gasFee);
            emit GasFeeCharged(USDT, abi.decode(data, (address)), gasFee);
        }
        _oft(to, amount - gasFee, minAmountLD);
        emit BridgeBack(msg.sender, recipient, to, amount - gasFee, minAmountLD);
        _status = 1;
    }

    function _ok(address recipient) private view returns (bool) {
        return address(this)
            == address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                FACTORY,
                                keccak256(abi.encode(recipient)),
                                keccak256(
                                    abi.encodePacked(
                                        hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                                        IMPLEMENTATION,
                                        hex"5af43d82803e903d91602b57fd5bf3"
                                    )
                                )
                            )
                        )
                    )
                )
            );
    }

    function _curve(uint256 swapType, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        private
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (
            tokenIn != DAI && tokenIn != USDC && tokenIn != USDT && tokenIn != PYUSD && tokenIn != CRVUSD
                && tokenIn != RLUSD
        ) revert UnknownToken();
        if (
            tokenOut != DAI && tokenOut != USDC && tokenOut != USDT && tokenOut != PYUSD && tokenOut != CRVUSD
                && tokenOut != RLUSD
        ) revert UnknownToken();
        address pool = swapType == 0
            ? POOL_3POOL
            : swapType == 1
                ? POOL_USDC_USDT
                : swapType == 2 ? POOL_PYUSD_USDC : swapType == 3 ? POOL_CRVUSD_USDC : swapType == 4 ? POOL_USDC_RLUSD : address(0);
        if (pool == address(0)) revert UnknownPool();

        uint256 i = 3;
        uint256 j = 3;
        for (uint256 k; k < 3; ++k) {
            address coin;
            bool ok;
            assembly {
                let p := mload(0x40)
                mstore(p, 0xc661065700000000000000000000000000000000000000000000000000000000)
                mstore(add(p, 0x04), k)
                ok := staticcall(gas(), pool, p, 0x24, p, 0x20)
                ok := and(ok, iszero(lt(returndatasize(), 32)))
                if ok { coin := mload(p) }
            }
            if (!ok) break;
            if (coin == tokenIn) i = k;
            if (coin == tokenOut) j = k;
        }
        if (i == 3 || j == 3) revert UnknownToken();
        if (i == j) revert SameToken();

        assembly {
            let p := mload(0x40)
            mstore(p, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), pool)
            mstore(add(p, 0x24), 0)
            if iszero(call(gas(), tokenIn, 0, p, 0x44, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            mstore(add(p, 0x24), amountIn)
            if iszero(call(gas(), tokenIn, 0, p, 0x44, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        uint256 beforeOut;
        assembly {
            let p := mload(0x40)
            mstore(p, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), address())
            if staticcall(gas(), tokenOut, p, 0x24, p, 0x20) { beforeOut := mload(p) }
        }
        if (swapType == 0) {
            assembly {
                let p := mload(0x40)
                mstore(p, 0x3df0212400000000000000000000000000000000000000000000000000000000)
                mstore(add(p, 0x04), i)
                mstore(add(p, 0x24), j)
                mstore(add(p, 0x44), amountIn)
                mstore(add(p, 0x64), minAmountOut)
                if iszero(call(gas(), pool, 0, p, 0x84, 0, 0)) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        } else {
            assembly {
                let p := mload(0x40)
                mstore(p, 0xddc1f59d00000000000000000000000000000000000000000000000000000000)
                mstore(add(p, 0x04), i)
                mstore(add(p, 0x24), j)
                mstore(add(p, 0x44), amountIn)
                mstore(add(p, 0x64), minAmountOut)
                mstore(add(p, 0x84), address())
                if iszero(call(gas(), pool, 0, p, 0xa4, 0, 0)) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        }
        uint256 afterOut;
        assembly {
            let p := mload(0x40)
            mstore(p, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), address())
            if staticcall(gas(), tokenOut, p, 0x24, p, 0x20) { afterOut := mload(p) }
        }
        amountOut = afterOut - beforeOut;
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        assembly {
            let p := mload(0x40)
            mstore(p, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), pool)
            mstore(add(p, 0x24), 0)
            pop(call(gas(), tokenIn, 0, p, 0x44, 0, 0))
        }
    }

    /// @dev UsdtOFT `quoteOFT` 低于 `minAmountLD` 则 `Slippage`。`to` 左补 `0x41` 成波场 T 地址。
    function _oft(address to, uint256 amount, uint256 minAmountLD) private {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || minAmountLD == 0) revert ZeroAmount();
        if (minAmountLD > amount) revert Slippage(amount, minAmountLD);
        uint256 quoted;
        assembly {
            let p := mload(0x40)
            mstore(p, 0x0d35b41500000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), 0x20)
            let b := add(p, 0x24)
            mstore(b, LZ_EID_TRON)
            mstore(add(b, 0x20), or(shl(160, 0x41), to))
            mstore(add(b, 0x40), amount)
            mstore(add(b, 0x60), minAmountLD)
            mstore(add(b, 0x80), 0xe0)
            mstore(add(b, 0xa0), 0x100)
            mstore(add(b, 0xc0), 0x120)
            mstore(add(b, 0xe0), 0)
            mstore(add(b, 0x100), 0)
            mstore(add(b, 0x120), 0)
            if iszero(staticcall(gas(), USDT_OFT, p, 0x164, p, 0xa0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            quoted := mload(add(p, 0x80))
        }
        if (quoted < minAmountLD) revert Slippage(quoted, minAmountLD);
        assembly {
            let p := mload(0x40)
            mstore(p, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), USDT_OFT)
            mstore(add(p, 0x24), 0)
            if iszero(call(gas(), USDT, 0, p, 0x44, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            mstore(add(p, 0x24), amount)
            if iszero(call(gas(), USDT, 0, p, 0x44, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            mstore(p, 0xc7c7f5b300000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), 0x80)
            mstore(add(p, 0x24), callvalue())
            mstore(add(p, 0x44), 0)
            mstore(add(p, 0x64), caller())
            let b := add(p, 0x84)
            mstore(b, LZ_EID_TRON)
            mstore(add(b, 0x20), or(shl(160, 0x41), to))
            mstore(add(b, 0x40), amount)
            mstore(add(b, 0x60), minAmountLD)
            mstore(add(b, 0x80), 0xe0)
            mstore(add(b, 0xa0), 0x100)
            mstore(add(b, 0xc0), 0x120)
            mstore(add(b, 0xe0), 0)
            mstore(add(b, 0x100), 0)
            mstore(add(b, 0x120), 0)
            if iszero(call(gas(), USDT_OFT, callvalue(), p, 0x1c4, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            mstore(p, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), USDT_OFT)
            mstore(add(p, 0x24), 0)
            pop(call(gas(), USDT, 0, p, 0x44, 0, 0))
        }
    }

    function _send(address token, address to, uint256 amount) private {
        assembly {
            let p := mload(0x40)
            mstore(p, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 0x04), to)
            mstore(add(p, 0x24), amount)
            if iszero(call(gas(), token, 0, p, 0x44, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
