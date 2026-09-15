// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.28;

/// @title 稳定币兑换与跨链路由
/// @notice 同链 Curve 兑换；methodType 1/2 经主网 UsdtOFT（LayerZero V2 OFT）`send` 跨出 **USDT**。
/// @dev 主网 Router：`0x4A760E4c0Af6F369E07A97C5ED75E626c1369070`。
///      跨链须先 `quote` 再 `execute{value: nativeFee}`。目的链仅波场：EID `30420` 或 chainId `728126428`。
///      `ACROSS_PROTOCOL` 名为历史遗留，实为 ETH UsdtOFT `0x1F748c76…`。反向见 `StablecoinBridgeTron`。
///      文档：`StablecoinBridgeRouter.md` / `StablecoinBridge.md`。
contract StablecoinBridgeRouter {
    /// @notice 合约 owner 变更
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    /// @notice Curve 兑换完成（跨链前也会发，此时 token 仍在本合约）
    /// @param amountIn 扣费后实际进入 Curve 池的 tokenIn 数量
    /// @param amountOut 池子打出的 tokenOut 数量（尚未跨链）
    event Swap(
        address indexed sender,
        address indexed recipient,
        address indexed pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    /// @notice UsdtOFT 已 `send`（LayerZero）。`amount` 为目的链预计到账（扣 Mesh 费后）。
    event Bridge(
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 destChainId
    );
    /// @notice 协议费已从本笔 tokenIn 中划出并留在本合约（发生在兑换/转出之前）
    event FeeCharged(address indexed token, address indexed holder, uint256 fee);
    /// @notice `claimFee` 收款地址更新
    event FeeRecipientUpdated(address feeRecipient);

    address private _owner;
    address private _feeRecipient;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    /// @dev 协议费固定 2 bps：`amountIn * PROTOCOL_FEE_BPS / BPS_DENOMINATOR`。
    uint256 public constant PROTOCOL_FEE_BPS = 2;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    /// @dev 跨链 `destAmount` 不得低于成交时 `quoteOFT.amountReceivedLD` 的 99%。
    uint256 public constant OFT_MIN_BPS = 9_900;
    uint32 public constant LZ_EID_TRON = 30420;
    uint256 public constant TRON_CHAIN_ID = 728126428;

    /// @dev `swapType`：走哪一个 Curve 池（仅 methodType 0/1 需要兑换时有意义）
    uint256 public constant TYPE_3POOL = 0;
    uint256 public constant TYPE_USDC_USDT = 1;
    uint256 public constant TYPE_PYUSD_USDC = 2;
    uint256 public constant TYPE_CRVUSD_USDC = 3;
    uint256 public constant TYPE_USDC_RLUSD = 4;

    /// @dev `methodType`：0 只兑换；1 兑成 USDT 后 UsdtOFT.send；2 USDT 直接 send。
    uint256 public constant METHOD_SWAP = 0;
    uint256 public constant METHOD_SWAP_BRIDGE = 1;
    uint256 public constant METHOD_BRIDGE = 2;

    /// @dev 常量名历史遗留：实际是以太坊 UsdtOFT（USDT0 Legacy Mesh），不是 Across SpokePool。
    ///      波场 peer：`0x3a08F76772e200653bB55c2a92998DAcA62e0e97`（`TFG4wBa…`），见 `StablecoinBridgeTron`。
    address public constant ACROSS_PROTOCOL = 0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0;
    address public constant POOL_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address public constant POOL_USDC_USDT = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
    address public constant POOL_PYUSD_USDC = 0x383E6b4437b59fff47B619CBA855CA29342A8559;
    address public constant POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant POOL_USDC_RLUSD = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error UnknownToken(address token);
    error UnknownPool(uint256 swapType);
    error InvalidMethodType(uint256 methodType);
    error SameToken();
    error ZeroAmount();
    error Slippage(uint256 amountOut, uint256 minAmountOut);
    error ZeroAddress();
    error ExchangeFailed();
    error FeeExceedsAmount(uint256 fee, uint256 amount);
    error ClaimFailed();
    error ReentrancyGuardReentrantCall();
    error UnknownDestChain(uint256 destChainId);
    error BridgeTokenMustBeUsdt();
    error NativeFeeMismatch(uint256 required, uint256 given);

    modifier onlyOwner() {
        if (_owner != msg.sender) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyGuardReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(address initOwner) payable {
        if (initOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _owner = initOwner;
        emit OwnerChanged(address(0), initOwner);
        _status = _NOT_ENTERED;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        emit OwnerChanged(_owner, newOwner);
        _owner = newOwner;
    }

    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        _feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /// @notice 把本合约持有的 `token`（含累计手续费；`token==address(0)` 表示 ETH）转给 `feeRecipient`。
    /// @param amount `1` 表示全部余额，其它值表示转出数量（不可超过余额）。
    function claimFee(address token, uint256 amount) external onlyOwner nonReentrant {
        address to = _feeRecipient;
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (token == address(0)) {
            uint256 bal = address(this).balance;
            uint256 sendEth = amount == 1 ? bal : amount;
            if (sendEth == 0) return;
            if (sendEth > bal) revert FeeExceedsAmount(sendEth, bal);
            bool failed;
            assembly {
                failed := iszero(call(gas(), to, sendEth, 0, 0, 0, 0))
            }
            if (failed) revert ClaimFailed();
            return;
        }

        uint256 balanceToken = _balanceOf(token, address(this));
        uint256 sendAmt = amount == 1 ? balanceToken : amount;
        if (sendAmt == 0) return;
        if (sendAmt > balanceToken) revert FeeExceedsAmount(sendAmt, balanceToken);
        _safeTransfer(token, to, sendAmt);
    }

    /// @notice `swapType` → Curve 池地址
    function poolOf(uint256 swapType) internal pure returns (address) {
        if (swapType == TYPE_3POOL) return POOL_3POOL;
        if (swapType == TYPE_USDC_USDT) return POOL_USDC_USDT;
        if (swapType == TYPE_PYUSD_USDC) return POOL_PYUSD_USDC;
        if (swapType == TYPE_CRVUSD_USDC) return POOL_CRVUSD_USDC;
        if (swapType == TYPE_USDC_RLUSD) return POOL_USDC_RLUSD;
        revert UnknownPool(swapType);
    }

    function dstEidOf(uint256 destChainId) internal pure returns (uint32) {
        if (destChainId == LZ_EID_TRON || destChainId == TRON_CHAIN_ID) return LZ_EID_TRON;
        revert UnknownDestChain(destChainId);
    }

    /// @notice 组装 UsdtOFT `SendParam.to`（波场 T 地址规则）。
    /// @dev T 地址 hex = `41` + 20 字节；再左补 11 字节 0 成 bytes32。
    ///      `recipient` 只传去掉 `41` 后的 20 字节，跨链不可为 0。
    function oftTo(uint256 destChainId, address recipient) internal pure returns (bytes32) {
        dstEidOf(destChainId);
        if (recipient == address(0)) revert ZeroAddress();
        return bytes32((uint256(0x41) << 160) | uint256(uint160(recipient)));
    }

    /// @notice 询价。只兑：`outAmount` 为扣费后 `get_dy`，`nativeFee=0`。跨链：`outAmount` 写入 `execute` 的 `destAmount`，`nativeFee` 作 `msg.value`。
    function quote(
        uint256 swapType,
        uint256 methodType,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 destChainId,
        address destToken
    ) public view returns (uint256 outAmount, uint256 nativeFee) {
        _assertParam(methodType, tokenIn, tokenOut, recipient, destChainId, destToken);
        uint256 netIn = amountIn - (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        if (methodType == METHOD_SWAP) {
            outAmount = _getAmountOut(swapType, tokenIn, tokenOut, netIn);
            return (outAmount, 0);
        }
        uint256 usdtAmt = methodType == METHOD_BRIDGE
            ? netIn
            : _getAmountOut(swapType, tokenIn, tokenOut, netIn);
        uint32 dstEid = dstEidOf(destChainId);
        bytes32 to = oftTo(destChainId, recipient);
        outAmount = _oftQuoteReceived(dstEid, to, usdtAmt, 0);
        nativeFee = _oftQuoteNativeFee(dstEid, to, usdtAmt, outAmount);
    }

    /// @notice 拉 tokenIn → 划费 →（可选）Curve → methodType 0 转给 recipient，methodType 1/2 对 UsdtOFT `send`。
    /// @dev 跨链先 `quote`，`msg.value` 必须等于 `nativeFee`，不退多余 ETH。
    function execute(
        uint256 swapType,
        uint256 methodType,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 destChainId,
        address destToken,
        uint256 destAmount,
        uint256 nativeFee
    ) external payable nonReentrant returns (uint256 outAmount) {
        if (amountIn == 0) revert ZeroAmount();
        {
            uint256 needEth = methodType == METHOD_SWAP ? 0 : nativeFee;
            if (msg.value != needEth) revert NativeFeeMismatch(needEth, msg.value);
        }
        _assertParam(methodType, tokenIn, tokenOut, recipient, destChainId, destToken);
        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        if (recipient == address(0)) recipient = msg.sender;
        {
            uint256 fee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
            if (fee != 0) emit FeeCharged(tokenIn, address(this), fee);
            amountIn -= fee;
        }
        if (methodType == METHOD_BRIDGE) {
            return _oftSend(recipient, destChainId, destAmount, nativeFee, amountIn);
        }
        {
            outAmount = _curveSwap(swapType, tokenIn, tokenOut, amountIn, minAmountOut);
            emit Swap(msg.sender, recipient, poolOf(swapType), tokenIn, tokenOut, amountIn, outAmount);
        }
        if (methodType == METHOD_SWAP) {
            _safeTransfer(tokenOut, recipient, outAmount);
            return outAmount;
        }
        return _oftSend(recipient, destChainId, destAmount, nativeFee, outAmount);
    }

    /// @dev Curve `get_dy` ABI 为 `(int128,int128,uint256)`；下标 0/1/2 用 uint256 mstore 即可。
    function _getAmountOut(
        uint256 swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 dy) {
        address pool = poolOf(swapType);
        uint256 i = _index(pool, tokenIn);
        uint256 j = _index(pool, tokenOut);
        if (i == j) revert SameToken();
        bool failed;
        assembly {
            let emptyPointer := mload(0x40)
            // calldata: selector(4) + i(32) + j(32) + dx(32) = 0x64
            mstore(emptyPointer, 0x5e0d443f00000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), i)
            mstore(add(emptyPointer, 0x24), j)
            mstore(add(emptyPointer, 0x44), amountIn)
            // 只读报价，staticcall；成功时返回值写回 emptyPointer
            let success := staticcall(gas(), pool, emptyPointer, 0x64, emptyPointer, 0x20)
            failed := or(iszero(success), lt(returndatasize(), 32))
            if iszero(failed) {
                dy := mload(emptyPointer)
            }
        }
        if (failed) revert ExchangeFailed();
    }

    /// @dev 3pool：`exchange` selector `0x3df02124`，兑出到本合约。
    ///      NG：`exchange`+receiver `0xddc1f59d`，receiver 为本合约。
    function _curveSwap(
        uint256 swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        address pool = poolOf(swapType);
        uint256 i = _index(pool, tokenIn);
        uint256 j = _index(pool, tokenOut);
        if (i == j) revert SameToken();
        _safeApprove(tokenIn, pool, amountIn);
        uint256 beforeOut = _balanceOf(tokenOut, address(this));
        if (swapType == TYPE_3POOL) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, 0x3df0212400000000000000000000000000000000000000000000000000000000)
                mstore(add(ptr, 0x04), i)
                mstore(add(ptr, 0x24), j)
                mstore(add(ptr, 0x44), amountIn)
                mstore(add(ptr, 0x64), minAmountOut)
                if iszero(call(gas(), pool, 0, ptr, 0x84, 0, 0)) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        } else {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, 0xddc1f59d00000000000000000000000000000000000000000000000000000000)
                mstore(add(ptr, 0x04), i)
                mstore(add(ptr, 0x24), j)
                mstore(add(ptr, 0x44), amountIn)
                mstore(add(ptr, 0x64), minAmountOut)
                mstore(add(ptr, 0x84), address())
                if iszero(call(gas(), pool, 0, ptr, 0xa4, 0, 0)) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        }
        amountOut = _balanceOf(tokenOut, address(this)) - beforeOut;
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        _safeApprove(tokenIn, pool, 0);
    }

    /// @dev 第二步：用调用方传入的 destAmount / nativeFee 调 UsdtOFT.send，不再链上 quoteSend。
    function _oftSend(
        address recipient,
        uint256 destChainId,
        uint256 destAmount,
        uint256 nativeFee,
        uint256 usdtAmt
    ) internal returns (uint256 received) {
        if (usdtAmt == 0) revert ZeroAmount();
        if (destAmount == 0) revert ZeroAmount();

        {
            uint32 dstEid = dstEidOf(destChainId);
            bytes32 to = oftTo(destChainId, recipient);
            uint256 minLd = destAmount;
            if (minLd > usdtAmt) {
                minLd = usdtAmt;
            }
            {
                uint256 quoted = _oftQuoteReceived(dstEid, to, usdtAmt, minLd);
                uint256 minOk = (quoted * OFT_MIN_BPS) / BPS_DENOMINATOR;
                if (minOk == 0) revert ZeroAmount();
                if (destAmount < minOk) revert Slippage(destAmount, minOk);
            }
            _safeApprove(USDT, ACROSS_PROTOCOL, usdtAmt);
            {
                address oft = ACROSS_PROTOCOL;
                address refund = msg.sender;
                assembly {
                    let ptr := mload(0x40)
                    mstore(ptr, 0xc7c7f5b300000000000000000000000000000000000000000000000000000000)
                    mstore(add(ptr, 0x04), 0x80)
                    mstore(add(ptr, 0x24), nativeFee)
                    mstore(add(ptr, 0x44), 0)
                    mstore(add(ptr, 0x64), refund)
                }
                uint256 body;
                assembly {
                    body := add(mload(0x40), 0x84)
                }
                _oftWriteSendParamBody(body, dstEid, to, usdtAmt, minLd);
                assembly {
                    let ptr := mload(0x40)
                    mstore(0x40, add(ptr, 0x1c4))
                    if iszero(call(gas(), oft, nativeFee, ptr, 0x1c4, ptr, 0xc0)) {
                        returndatacopy(0, 0, returndatasize())
                        revert(0, returndatasize())
                    }
                    if lt(returndatasize(), 0xc0) {
                        revert(0, 0)
                    }
                    received := mload(add(ptr, 0xa0))
                }
            }
        }
        _safeApprove(USDT, ACROSS_PROTOCOL, 0);

        emit Bridge(msg.sender, recipient, USDT, received, destChainId);
    }

    /// @dev 把 UsdtOFT SendParam 编进内存（相对结构体起点 0x140 字节）。
    /// SendParam: uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD,
    ///            bytes extraOptions, bytes composeMsg, bytes oftCmd。
    /// 后三个 bytes 固定空：head 里 offset 0xe0 / 0x100 / 0x120，随后各 32 字节 length=0。
    function _oftWriteSendParamBody(
        uint256 p,
        uint32 dstEid,
        bytes32 to,
        uint256 amountLD,
        uint256 minAmountLD
    ) private pure {
        assembly {
            mstore(p, dstEid)
            mstore(add(p, 0x20), to)
            mstore(add(p, 0x40), amountLD)
            mstore(add(p, 0x60), minAmountLD)
            mstore(add(p, 0x80), 0xe0)
            mstore(add(p, 0xa0), 0x100)
            mstore(add(p, 0xc0), 0x120)
            mstore(add(p, 0xe0), 0)
            mstore(add(p, 0x100), 0)
            mstore(add(p, 0x120), 0)
        }
    }

    /// @dev UsdtOFT quoteOFT(SendParam) view。
    /// 函数签名: quoteOFT((uint32,bytes32,uint256,uint256,bytes,bytes,bytes))
    /// Selector: 0x0d35b415
    /// 返回: (OFTLimit{minAmountLD,maxAmountLD}, OFTFeeDetail[]{feeAmountLD,description}[],
    ///        OFTReceipt{amountSentLD,amountReceivedLD})
    /// calldata: selector(4) + 动态参数 offset 0x20(32) + SendParam 体(0x140) = 0x164
    /// 返回 ABI 头 5 word：Limit 2 + 数组 offset 1 + Receipt 2；amountReceivedLD 在 0x80。
    function _oftQuoteReceived(
        uint32 dstEid,
        bytes32 to,
        uint256 amountLD,
        uint256 minAmountLD
    ) internal view returns (uint256 amountReceivedLD) {
        address oft = ACROSS_PROTOCOL;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x0d35b41500000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), 0x20)
        }
        uint256 body;
        assembly {
            body := add(mload(0x40), 0x24)
        }
        _oftWriteSendParamBody(body, dstEid, to, amountLD, minAmountLD);
        assembly {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x164))
            if iszero(staticcall(gas(), oft, ptr, 0x164, ptr, 0xa0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            if lt(returndatasize(), 0xa0) {
                revert(0, 0)
            }
            amountReceivedLD := mload(add(ptr, 0x80))
        }
    }

    /// @dev UsdtOFT quoteSend(SendParam, payInLzToken=false) view。
    /// 函数签名: quoteSend((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),bool)
    /// Selector: 0x3b6f743b
    /// 返回: MessagingFee{nativeFee, lzTokenFee}；本合约只取 nativeFee（偏移 0x00）。
    /// calldata: selector(4) + SendParam offset 0x40(32) + false(32) + SendParam 体(0x140) = 0x184
    function _oftQuoteNativeFee(
        uint32 dstEid,
        bytes32 to,
        uint256 amountLD,
        uint256 minAmountLD
    ) internal view returns (uint256 nativeFee) {
        address oft = ACROSS_PROTOCOL;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3b6f743b00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), 0x40)
            mstore(add(ptr, 0x24), 0)
        }
        uint256 body;
        assembly {
            body := add(mload(0x40), 0x44)
        }
        _oftWriteSendParamBody(body, dstEid, to, amountLD, minAmountLD);
        assembly {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x184))
            if iszero(staticcall(gas(), oft, ptr, 0x184, ptr, 0x40)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            if lt(returndatasize(), 0x20) {
                revert(0, 0)
            }
            nativeFee := mload(ptr)
        }
    }

    function _assertParam(
        uint256 methodType,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 destChainId,
        address destToken
    ) private pure {
        if (methodType > METHOD_BRIDGE) revert InvalidMethodType(methodType);
        if (destToken != address(0) && destToken != USDT) revert BridgeTokenMustBeUsdt();
        if (methodType == METHOD_SWAP) {
            if (!_isListed(tokenIn)) revert UnknownToken(tokenIn);
            if (!_isListed(tokenOut)) revert UnknownToken(tokenOut);
            return;
        }
        dstEidOf(destChainId);
        if (recipient == address(0)) revert ZeroAddress();
        if (methodType == METHOD_BRIDGE) {
            if (tokenIn != USDT) revert BridgeTokenMustBeUsdt();
            return;
        }
        if (!_isListed(tokenIn)) revert UnknownToken(tokenIn);
        if (tokenOut != USDT) revert BridgeTokenMustBeUsdt();
    }

    /// @dev 读池子 `coins(uint256)`，selector `0xc6610657`。最多 3 币（3pool）；NG 在 k=2 失败即停。
    function _index(address pool, address token) internal view returns (uint256) {
        for (uint256 k; k < 3; ++k) {
            address coin;
            bool ok;
            assembly {
                let emptyPointer := mload(0x40)
                // calldata: selector(4) + index(32) = 0x24
                mstore(emptyPointer, 0xc661065700000000000000000000000000000000000000000000000000000000)
                mstore(add(emptyPointer, 0x04), k)
                // 只读 coins(k)；失败或返回不足 32 字节视为该下标不存在
                ok := staticcall(gas(), pool, emptyPointer, 0x24, emptyPointer, 0x20)
                ok := and(ok, iszero(lt(returndatasize(), 32)))
                if ok {
                    coin := mload(emptyPointer)
                }
            }
            if (!ok) break;
            if (coin == token) {
                return k;
            }
        }
        revert UnknownToken(token);
    }

    function _isListed(address token) private pure returns (bool) {
        return token == DAI || token == USDC || token == USDT || token == PYUSD || token == CRVUSD || token == RLUSD;
    }

    /// @dev ERC20 `balanceOf(address)`，selector `0x70a08231`。失败时返回 0。
    function _balanceOf(address token, address holder) internal view returns (uint256 tokenBal) {
        assembly {
            let emptyPointer := mload(0x40)
            // calldata: selector(4) + holder(32) = 0x24
            mstore(emptyPointer, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), holder)
            // 只读余额；成功时从 emptyPointer 取 uint256（此处 out 长度 0x40 与常用写法一致）
            let success := staticcall(gas(), token, emptyPointer, 0x24, emptyPointer, 0x40)
            if success {
                tokenBal := mload(emptyPointer)
            }
        }
    }

    /// @dev `transfer(address,uint256)` 0xa9059cbb
    function _safeTransfer(address token, address recipient, uint256 amount) internal {
        assembly {
            let emptyPointer := mload(0x40)
            mstore(emptyPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), recipient)
            mstore(add(emptyPointer, 0x24), amount)
            if iszero(call(gas(), token, 0, emptyPointer, 0x44, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// @dev `transferFrom(address,address,uint256)` 0x23b872dd
    function _safeTransferFrom(address token, address from, address recipient, uint256 amount) internal {
        assembly {
            let emptyPointer := mload(0x40)
            mstore(emptyPointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), from)
            mstore(add(emptyPointer, 0x24), recipient)
            mstore(add(emptyPointer, 0x44), amount)
            if iszero(call(gas(), token, 0, emptyPointer, 0x64, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// @dev `approve(address,uint256)` 0x095ea7b3。先置 0 再授权，兼容 USDT。
    function _safeApprove(address token, address spender, uint256 amount) internal {
        if (amount != 0) _tokenApprove(token, spender, 0);
        _tokenApprove(token, spender, amount);
    }

    function _tokenApprove(address token, address spender, uint256 amount) internal {
        assembly {
            let emptyPointer := mload(0x40)
            mstore(emptyPointer, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), spender)
            mstore(add(emptyPointer, 0x24), amount)
            if iszero(call(gas(), token, 0, emptyPointer, 0x44, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    receive() external payable {}
    fallback() external payable {}
}
