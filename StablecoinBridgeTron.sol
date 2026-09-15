// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.11;

/// @title 波场 USDT → 以太坊跨链入口
/// @notice 只跨链，不 swap。拉 TRC20 USDT → 扣 2 bps → UsdtOFT.send 到以太坊。
/// @dev 主网：`TG1tdbbj4crisqw6DZPeApAFnUE72mYh5R`（hex `0x4252aB0602F78706d9091135d6108ab99A4dC43B`）。
///      须先 `quote`，再 `execute{value: nativeFee}`（TRX sun）。`msg.value` 必须相等，不退多余 TRX。
///      `quote` 已扣 2 bps 再询 OFT。跨链后再兑走以太坊 Curve 官方池，不经本合约。
///      旧址 `TTF3ja…`（错误 OFT）已废弃。文档见 `StablecoinBridgeTron.md` / `StablecoinBridge.md`。
contract StablecoinBridgeTron {
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event Bridge(
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 destChainId
    );
    event FeeCharged(address indexed token, address indexed holder, uint256 fee);
    event FeeRecipientUpdated(address feeRecipient);

    address private _owner;
    address private _feeRecipient;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    uint256 public constant PROTOCOL_FEE_BPS = 2;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 public constant OFT_MIN_BPS = 9_900;
    uint32 public constant LZ_EID_ETH = 30101;
    uint256 public constant ETH_CHAIN_ID = 1;

    /// @dev 波场主网 TRC20 USDT：TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t
    address public constant USDT = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    /// @dev 以太坊 USDT，仅用于 `destToken` 校验。
    address public constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @dev 波场 UsdtOFT（USDT0 Legacy Mesh）：`TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt`。
    ///      等于 ETH UsdtOFT `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0.peers(30420)`（须 EIP-55 校验和）。
    address public constant USDT_OFT = 0x3a08F76772e200653bB55c2a92998DAcA62e0e97;

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error ZeroAmount();
    error Slippage(uint256 amountOut, uint256 minAmountOut);
    error ZeroAddress();
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

    /// @notice 提取本合约持有的 token（`token==0` 为 TRX）到 `feeRecipient`。`amount==1` 表示全部。
    function claimFee(address token, uint256 amount) external onlyOwner nonReentrant {
        address to = _feeRecipient;
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (token == address(0)) {
            uint256 bal = address(this).balance;
            uint256 sendTrx = amount == 1 ? bal : amount;
            if (sendTrx == 0) return;
            if (sendTrx > bal) revert FeeExceedsAmount(sendTrx, bal);
            bool failed;
            assembly {
                failed := iszero(call(gas(), to, sendTrx, 0, 0, 0, 0))
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

    function dstEidOf(uint256 destChainId) internal pure returns (uint32) {
        if (destChainId == LZ_EID_ETH || destChainId == ETH_CHAIN_ID) return LZ_EID_ETH;
        revert UnknownDestChain(destChainId);
    }

    /// @notice 以太坊 `SendParam.to`：12 字节 0 + 20 字节地址。`recipient` 为 ETH 收款地址。
    function oftTo(uint256 destChainId, address recipient) internal pure returns (bytes32) {
        dstEidOf(destChainId);
        if (recipient == address(0)) revert ZeroAddress();
        return bytes32(uint256(uint160(recipient)));
    }

    /// @notice 询价（只读）。先扣 2 bps，再 `quoteOFT` / `quoteSend`。
    /// @param recipient 以太坊收款地址（非 0）
    /// @param amountIn 波场 USDT 毛额（含协议费）
    /// @param destChainId `30101` 或 `1`
    /// @param destToken `0` 或 ETH USDT；仅校验，不参与发币
    /// @return outAmount 目的链预计到账 → 写入 `execute.destAmount`
    /// @return nativeFee TRX sun → 作 `execute` 的 `msg.value`
    function quote(
        address recipient,
        uint256 amountIn,
        uint256 destChainId,
        address destToken
    ) public view returns (uint256 outAmount, uint256 nativeFee) {
        _assertParam(recipient, destChainId, destToken);
        uint256 usdtAmt = amountIn - (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint32 dstEid = dstEidOf(destChainId);
        bytes32 to = oftTo(destChainId, recipient);
        outAmount = _oftQuoteReceived(dstEid, to, usdtAmt, 0);
        nativeFee = _oftQuoteNativeFee(dstEid, to, usdtAmt, outAmount);
    }

    /// @notice 拉 USDT → 划 2 bps → UsdtOFT.send。`msg.value` 必须等于 `nativeFee`（sun）。
    /// @param destToken 同 `quote`：`0` 或 ETH USDT，仅校验
    /// @param destAmount / nativeFee 须用当次 `quote` 原样回填
    function execute(
        address recipient,
        uint256 amountIn,
        uint256 destChainId,
        address destToken,
        uint256 destAmount,
        uint256 nativeFee
    ) external payable nonReentrant returns (uint256) {
        if (amountIn == 0) revert ZeroAmount();
        if (msg.value != nativeFee) revert NativeFeeMismatch(nativeFee, msg.value);
        _assertParam(recipient, destChainId, destToken);
        _safeTransferFrom(USDT, msg.sender, address(this), amountIn);
        {
            uint256 fee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
            if (fee != 0) emit FeeCharged(USDT, address(this), fee);
            amountIn -= fee;
        }
        return _oftSend(recipient, destChainId, destAmount, nativeFee, amountIn);
    }

    function _assertParam(address recipient, uint256 destChainId, address destToken) private pure {
        if (destToken != address(0) && destToken != ETH_USDT) revert BridgeTokenMustBeUsdt();
        dstEidOf(destChainId);
        if (recipient == address(0)) revert ZeroAddress();
    }

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
            _safeApprove(USDT, USDT_OFT, usdtAmt);
            {
                address oft = USDT_OFT;
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
        _safeApprove(USDT, USDT_OFT, 0);

        emit Bridge(msg.sender, recipient, USDT, received, destChainId);
    }

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

    function _oftQuoteReceived(
        uint32 dstEid,
        bytes32 to,
        uint256 amountLD,
        uint256 minAmountLD
    ) internal view returns (uint256 amountReceivedLD) {
        address oft = USDT_OFT;
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

    function _oftQuoteNativeFee(
        uint32 dstEid,
        bytes32 to,
        uint256 amountLD,
        uint256 minAmountLD
    ) internal view returns (uint256 nativeFee) {
        address oft = USDT_OFT;
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

    function _balanceOf(address token, address holder) internal view returns (uint256 tokenBal) {
        assembly {
            let emptyPointer := mload(0x40)
            mstore(emptyPointer, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), holder)
            let success := staticcall(gas(), token, emptyPointer, 0x24, emptyPointer, 0x40)
            if success {
                tokenBal := mload(emptyPointer)
            }
        }
    }

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
