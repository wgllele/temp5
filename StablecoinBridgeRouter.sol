// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.28;

/// @title 稳定币兑换与跨链路由
/// @notice 同链 Curve 兑换；route 1/2 经主网 UsdtOFT（LayerZero V2 OFT）`send` 跨出 **USDT**。
/// @dev 跨链须 `execute{value: nativeFee}`。目的链仅波场：EID `30420` 或 chainId `728126428`。
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
    event FeeCharged(address indexed token, address indexed holder, uint256 fee, uint8 feeMode);
    /// @notice 比例费率或收费地址更新（固定费仍用每笔 `swapFee`）
    event FeeInfoUpdated(uint24 feeRate, address feeRecipient);

    address private _owner;
    /// @dev 比例收费配置；`feeRate==0` 时比例模式不扣费。手续费留在本合约，由 owner `claimFee` 转到 `feeRecipient`。
    FeeInfo private _feeInfo;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    /// @dev 比例费分母。`feeRate=100` → 1 bps；上限 `MAX_FEE_RATE=1000` → 千分之一。
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint24 public constant MAX_FEE_RATE = 1_000;
    /// @dev 跨链 `destAmount` 不得低于成交时 `quoteOFT.amountReceivedLD` 的 99%。
    uint256 public constant OFT_MIN_BPS = 9_900;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint32 public constant LZ_EID_TRON = 30420;
    uint256 public constant TRON_CHAIN_ID = 728126428;

    /// @dev `swapType`：走哪一个 Curve 池（仅 route 需要兑换时有意义）
    uint8 public constant TYPE_3POOL = 0;
    uint8 public constant TYPE_USDC_USDT = 1;
    uint8 public constant TYPE_PYUSD_USDC = 2;
    uint8 public constant TYPE_CRVUSD_USDC = 3;
    uint8 public constant TYPE_USDC_RLUSD = 4;

    /// @dev methodType 低 4 位：路径。`ROUTE_SWAP` 与 `ROUTE_SWAP_ONLY` 同值。
    uint8 public constant ROUTE_SWAP = 0;
    uint8 public constant ROUTE_SWAP_ONLY = 0;
    uint8 public constant ROUTE_SWAP_BRIDGE = 1;
    uint8 public constant ROUTE_BRIDGE = 2;

    /// @dev methodType 高 4 位：收费方式。三种都在交易/跨链前从 tokenIn 扣。
    uint8 public constant FEE_FREE = 0;
    uint8 public constant FEE_FIXED = 1;
    uint8 public constant FEE_RATE = 2;

    /// @dev 预组好的 methodType，避免调用方自己移位。
    uint8 public constant METHOD_SWAP_FREE = 0x00;
    uint8 public constant METHOD_SWAP_FIXED = 0x10;
    uint8 public constant METHOD_SWAP_RATE = 0x20;
    uint8 public constant METHOD_SWAP_BRIDGE_FREE = 0x01;
    uint8 public constant METHOD_SWAP_BRIDGE_FIXED = 0x11;
    uint8 public constant METHOD_SWAP_BRIDGE_RATE = 0x21;
    uint8 public constant METHOD_BRIDGE_FREE = 0x02;
    uint8 public constant METHOD_BRIDGE_FIXED = 0x12;
    uint8 public constant METHOD_BRIDGE_RATE = 0x22;

    /// @dev 以太坊主网默认地址；构造参数为 0 时写入对应 immutable。
    /// @dev 主网 UsdtOFT（USDT0 Legacy Mesh），不是 Across SpokePool。
    address public constant DEFAULT_ACROSS_PROTOCOL = 0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0;
    address public constant DEFAULT_POOL_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address public constant DEFAULT_POOL_USDC_USDT = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
    address public constant DEFAULT_POOL_PYUSD_USDC = 0x383E6b4437b59fff47B619CBA855CA29342A8559;
    address public constant DEFAULT_POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant DEFAULT_POOL_USDC_RLUSD = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;
    address public constant DEFAULT_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant DEFAULT_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DEFAULT_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant DEFAULT_PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address public constant DEFAULT_CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant DEFAULT_RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    /// @notice ETH 侧 UsdtOFT，route 1/2 对其 `send`。
    address public immutable ACROSS_PROTOCOL;
    address public immutable POOL_3POOL;
    address public immutable POOL_USDC_USDT;
    address public immutable POOL_PYUSD_USDC;
    address public immutable POOL_CRVUSD_USDC;
    address public immutable POOL_USDC_RLUSD;
    address public immutable DAI;
    address public immutable USDC;
    address public immutable USDT;
    address public immutable PYUSD;
    address public immutable CRVUSD;
    address public immutable RLUSD;

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error UnknownToken(address token);
    error UnknownPool(uint8 swapType);
    error InvalidMethodType(uint8 methodType);
    error SameToken();
    error ZeroAmount();
    error Slippage(uint256 amountOut, uint256 minAmountOut);
    error InvalidFeeRate(uint24 feeRate);
    error ZeroAddress();
    error ExchangeFailed();
    error FeeExceedsAmount(uint256 fee, uint256 amount);
    error ClaimFailed();
    error ReentrancyGuardReentrantCall();
    error UnknownDestChain(uint256 destChainId);
    error BridgeTokenMustBeUsdt();
    error NativeFeeMismatch(uint256 required, uint256 given);

    /// @notice 构造注入地址；任一项为 `address(0)` 则用上方 DEFAULT_*。
    struct AddressConfig {
        address acrossProtocol;
        address pool3pool;
        address poolUsdcUsdt;
        address poolPyusdUsdc;
        address poolCrvusdUsdc;
        address poolUsdcRlusd;
        address dai;
        address usdc;
        address usdt;
        address pyusd;
        address crvusd;
        address rlusd;
    }

    /// @notice UsdtOFT `SendParam`（`extraOptions`/`composeMsg`/`oftCmd` 在本合约恒为空）。
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    /// @notice 单笔执行参数。跨链须先 `quoteBridge`，把 nativeFee / destAmount 填回来再 `execute`。
    /// @dev 槽 0：`uint8+uint8+uint32+uint208` 共 256 bit。
    /// @param destChainId 仅波场：`30420` 或 `728126428`。
    /// @param destAmount 询价 `quoteOFT` 的 minAmountLD。须 ≥ 成交时到账估值的 `OFT_MIN_BPS`/1e4。
    /// @param nativeFee 询价 `quoteSend(..., false)` 的 nativeFee（Wei）。跨链时 `msg.value` 必须相等；只兑必须为 0。
    /// @param destToken 非 0 时必须是 USDT。
    /// @param fillDeadline 未使用。
    struct SwapParam {
        uint8 swapType;
        uint8 methodType;
        uint32 fillDeadline;
        uint208 swapFee;
        address tokenIn;
        address tokenOut;
        address recipient;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 destChainId;
        address destToken;
        uint256 destAmount;
        uint256 nativeFee;
    }

    /// @param feeRate 比例费率，分母 1e6，最大 1000（千分之一）；仅 feeMode=比例时使用。
    /// @param feeRecipient `claimFee` 的收款地址。
    struct FeeInfo {
        uint24 feeRate;
        address feeRecipient;
    }

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

    /// @param initOwner 管理员，可改 owner 与 FeeInfo。
    /// @param addrs 池/代币/Across；字段为 0 则回落以太坊主网 DEFAULT_*。
    constructor(address initOwner, AddressConfig memory addrs) payable {
        if (initOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _owner = initOwner;
        emit OwnerChanged(address(0), initOwner);
        _status = _NOT_ENTERED;

        ACROSS_PROTOCOL = _orDefault(addrs.acrossProtocol, DEFAULT_ACROSS_PROTOCOL);
        POOL_3POOL = _orDefault(addrs.pool3pool, DEFAULT_POOL_3POOL);
        POOL_USDC_USDT = _orDefault(addrs.poolUsdcUsdt, DEFAULT_POOL_USDC_USDT);
        POOL_PYUSD_USDC = _orDefault(addrs.poolPyusdUsdc, DEFAULT_POOL_PYUSD_USDC);
        POOL_CRVUSD_USDC = _orDefault(addrs.poolCrvusdUsdc, DEFAULT_POOL_CRVUSD_USDC);
        POOL_USDC_RLUSD = _orDefault(addrs.poolUsdcRlusd, DEFAULT_POOL_USDC_RLUSD);
        DAI = _orDefault(addrs.dai, DEFAULT_DAI);
        USDC = _orDefault(addrs.usdc, DEFAULT_USDC);
        USDT = _orDefault(addrs.usdt, DEFAULT_USDT);
        PYUSD = _orDefault(addrs.pyusd, DEFAULT_PYUSD);
        CRVUSD = _orDefault(addrs.crvusd, DEFAULT_CRVUSD);
        RLUSD = _orDefault(addrs.rlusd, DEFAULT_RLUSD);
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

    function feeInfo() external view returns (FeeInfo memory) {
        return _feeInfo;
    }

    /// @notice 更新比例费率与收费地址。固定费金额在每笔 `swapFee` 里传，不在这里设。
    /// @dev `feeRate` 上限千分之一（`MAX_FEE_RATE`）；非 0 时必须带 `feeRecipient`（供日后 claim）。
    function setFeeInfo(FeeInfo calldata info) external onlyOwner {
        if (info.feeRate > MAX_FEE_RATE) revert InvalidFeeRate(info.feeRate);
        if (info.feeRate != 0 && info.feeRecipient == address(0)) revert ZeroAddress();
        _feeInfo = info;
        emit FeeInfoUpdated(info.feeRate, info.feeRecipient);
    }

    /// @notice 把本合约持有的 `token`（含累计手续费；`token==address(0)` 表示 ETH）转给 `FeeInfo.feeRecipient`。
    /// @param amount `1` 表示全部余额，其它值表示转出数量（不可超过余额）。
    function claimFee(address token, uint256 amount) external onlyOwner nonReentrant {
        address to = _feeInfo.feeRecipient;
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (token == address(0)) {
            uint256 bal = address(this).balance;
            uint256 sendEth = amount == 1 ? bal : amount;
            if (sendEth == 0) return;
            if (sendEth > bal) revert FeeExceedsAmount(sendEth, bal);
            _ethTransfer(to, sendEth);
            return;
        }

        uint256 balanceToken = _balanceOf(token, address(this));
        uint256 sendAmt = amount == 1 ? balanceToken : amount;
        if (sendAmt == 0) return;
        if (sendAmt > balanceToken) revert FeeExceedsAmount(sendAmt, balanceToken);
        _safeTransfer(token, to, sendAmt);
    }

    /// @notice 解析路径：0 只兑换；1 兑换成 USDT 后 UsdtOFT.send；2 USDT 直接 send
    function routeOf(uint8 methodType) public pure returns (uint8) {
        return methodType & 0x0f;
    }

    /// @notice 解析收费：0 免费、1 固定、2 比例
    function feeModeOf(uint8 methodType) public pure returns (uint8) {
        return methodType >> 4;
    }

    /// @notice 组装 methodType = route | (feeMode << 4)
    function encodeMethodType(uint8 route, uint8 feeMode) public pure returns (uint8) {
        if (route > ROUTE_BRIDGE) revert InvalidMethodType(route);
        if (feeMode > FEE_RATE) revert InvalidMethodType(feeMode);
        return route | uint8(feeMode << 4);
    }

    /// @notice `swapType` → Curve 池地址
    function poolOf(uint8 swapType) public view returns (address) {
        if (swapType == TYPE_3POOL) return POOL_3POOL;
        if (swapType == TYPE_USDC_USDT) return POOL_USDC_USDT;
        if (swapType == TYPE_PYUSD_USDC) return POOL_PYUSD_USDC;
        if (swapType == TYPE_CRVUSD_USDC) return POOL_CRVUSD_USDC;
        if (swapType == TYPE_USDC_RLUSD) return POOL_USDC_RLUSD;
        revert UnknownPool(swapType);
    }

    /// @notice DAI/USDC/USDT 默认 3pool（深度）；PYUSD/crvUSD/RLUSD 对 USDC 走对应 NG 2pool。
    ///         USDC↔USDT **小额**应显式 `TYPE_USDC_USDT`（NG 协议费率更低）；大额用 3pool。本函数无数量，无法按金额分流。
    function defaultSwapType(address tokenIn, address tokenOut) public view returns (uint8) {
        if (_is3(tokenIn) && _is3(tokenOut)) return TYPE_3POOL;
        if (_pair(tokenIn, tokenOut, PYUSD, USDC)) return TYPE_PYUSD_USDC;
        if (_pair(tokenIn, tokenOut, CRVUSD, USDC)) return TYPE_CRVUSD_USDC;
        if (_pair(tokenIn, tokenOut, RLUSD, USDC)) return TYPE_USDC_RLUSD;
        revert UnknownToken(tokenIn);
    }

    /// @notice `destChainId` → 波场 LayerZero EID `30420`。其它链 `UnknownDestChain`。
    function dstEidOf(uint256 destChainId) public pure returns (uint32) {
        if (destChainId == LZ_EID_TRON || destChainId == TRON_CHAIN_ID) return LZ_EID_TRON;
        revert UnknownDestChain(destChainId);
    }

    /// @notice 组装 UsdtOFT `SendParam.to`（波场 T 地址规则）。
    /// @dev T 地址 hex = `41` + 20 字节；再左补 11 字节 0 成 bytes32。
    ///      `recipient` 只传去掉 `41` 后的 20 字节，跨链不可为 0。
    function oftTo(uint256 destChainId, address recipient) public pure returns (bytes32) {
        dstEidOf(destChainId);
        if (recipient == address(0)) revert ZeroAddress();
        return bytes32((uint256(0x41) << 160) | uint256(uint160(recipient)));
    }

    /// @notice 第一步询价：UsdtOFT `quoteOFT` + `quoteSend(_sendParam, false)`。
    /// @return sendParam 与第二步 `send` 相同（`to` 已是 bytes32，其它 0x）
    /// @return nativeFee 写入 `SwapParam.nativeFee`，并作为 `execute{value: nativeFee}`
    /// @return minAmountLD 写入 `SwapParam.destAmount`
    function quoteBridge(SwapParam calldata param)
        external
        view
        returns (SendParam memory sendParam, uint256 nativeFee, uint256 minAmountLD)
    {
        uint8 route = routeOf(param.methodType);
        if (route == ROUTE_SWAP) revert InvalidMethodType(param.methodType);
        _assertRoute(param, route);
        sendParam = _oftSendParam(param, _bridgeUsdtAmount(param));
        minAmountLD = _oftQuoteReceived(sendParam.dstEid, sendParam.to, sendParam.amountLD, sendParam.minAmountLD);
        sendParam.minAmountLD = minAmountLD;
        nativeFee = _oftQuoteNativeFee(sendParam.dstEid, sendParam.to, sendParam.amountLD, minAmountLD);
    }

    function quoteBridgeNativeFee(SwapParam calldata param) external view returns (uint256 nativeFee) {
        uint8 route = routeOf(param.methodType);
        if (route == ROUTE_SWAP) revert InvalidMethodType(param.methodType);
        _assertRoute(param, route);
        SendParam memory sendParam = _oftSendParam(param, _bridgeUsdtAmount(param));
        uint256 minLd = _oftQuoteReceived(sendParam.dstEid, sendParam.to, sendParam.amountLD, sendParam.minAmountLD);
        nativeFee = _oftQuoteNativeFee(sendParam.dstEid, sendParam.to, sendParam.amountLD, minLd);
    }

    /// @notice 扣协议费后的到账：route 0 为 Curve `get_dy`；route 1/2 为 UsdtOFT `quoteOFT.amountReceivedLD`。
    function getAmountOut(SwapParam calldata param) external view returns (uint256) {
        return _bridgeUsdtAmountQuoted(param);
    }

    /// @notice 拉 tokenIn → 划费 →（可选）Curve → route 0 转给 recipient，route 1/2 对 UsdtOFT `send`。
    /// @dev 跨链先 `quoteBridge`，`msg.value` 必须等于 `nativeFee`，不退多余 ETH。
    function execute(SwapParam calldata param) external payable nonReentrant returns (uint256 outAmount) {
        if (param.amountIn == 0) revert ZeroAmount();
        address recipient = param.recipient;
        if (recipient == address(0)) {
            recipient = msg.sender;
        }
        uint8 route = routeOf(param.methodType);
        _assertRoute(param, route);
        uint256 needEth = route == ROUTE_SWAP ? 0 : param.nativeFee;
        if (msg.value != needEth) revert NativeFeeMismatch(needEth, msg.value);

        _safeTransferFrom(param.tokenIn, msg.sender, address(this), param.amountIn);
        uint256 netIn = _chargeFee(param.tokenIn, param.amountIn, param.methodType, param.swapFee);

        if (route == ROUTE_BRIDGE) {
            return _oftSend(param, recipient, netIn);
        }

        outAmount = _curveSwap(param.swapType, param.tokenIn, param.tokenOut, netIn, param.minAmountOut);
        emit Swap(msg.sender, recipient, poolOf(param.swapType), param.tokenIn, param.tokenOut, netIn, outAmount);

        if (route == ROUTE_SWAP) {
            _safeTransfer(param.tokenOut, recipient, outAmount);
            return outAmount;
        }

        return _oftSend(param, recipient, outAmount);
    }

    /// @dev Curve `get_dy(int128 i, int128 j, uint256 dx)`，selector `0x5e0d443f`。
    function _getAmountOut(
        uint8 swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 dy) {
        address pool = poolOf(swapType);
        (int128 i, int128 j) = _coins(pool, tokenIn, tokenOut);
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

    /// @dev 3pool：`exchange(int128,int128,uint256,uint256)` 无 receiver，兑出到本合约。
    ///      NG：`exchange(int128,int128,uint256,uint256,address)`，receiver 为本合约。
    function _curveSwap(
        uint8 swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        address pool = poolOf(swapType);
        (int128 i, int128 j) = _coins(pool, tokenIn, tokenOut);
        _safeApprove(tokenIn, pool, amountIn);
        uint256 beforeOut = _balanceOf(tokenOut, address(this));
        if (swapType == TYPE_3POOL) {
            _curveExchange3pool(pool, i, j, amountIn, minAmountOut);
        } else {
            _curveExchangeNg(pool, i, j, amountIn, minAmountOut);
        }
        amountOut = _balanceOf(tokenOut, address(this)) - beforeOut;
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        _safeApprove(tokenIn, pool, 0);
    }

    /// @dev 3pool `exchange(i, j, dx, min_dy)`。
    /// 函数签名: exchange(int128,int128,uint256,uint256)
    /// Selector: 0x3df02124
    /// calldata: selector(4) + i(32) + j(32) + dx(32) + min_dy(32) = 0x84
    function _curveExchange3pool(
        address pool,
        int128 i,
        int128 j,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal {
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
    }

    /// @dev NG `exchange(i, j, dx, min_dy, receiver)`，receiver 固定为本合约。
    /// 函数签名: exchange(int128,int128,uint256,uint256,address)
    /// Selector: 0xddc1f59d
    /// calldata: selector(4) + i(32) + j(32) + dx(32) + min_dy(32) + receiver(32) = 0xa4
    function _curveExchangeNg(
        address pool,
        int128 i,
        int128 j,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal {
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

    /// @dev 第二步：用调用方传入的 destAmount / nativeFee 调 UsdtOFT.send，不再链上 quoteSend。
    function _oftSend(SwapParam calldata param, address recipient, uint256 usdtAmt) internal returns (uint256 received) {
        if (usdtAmt == 0) revert ZeroAmount();
        if (param.destAmount == 0) revert ZeroAmount();

        SendParam memory sp = _oftSendParam(param, usdtAmt);
        if (sp.minAmountLD > usdtAmt) {
            sp.minAmountLD = usdtAmt;
        }
        uint256 quoted = _oftQuoteReceived(sp.dstEid, sp.to, sp.amountLD, sp.minAmountLD);
        uint256 minOk = (quoted * OFT_MIN_BPS) / BPS_DENOMINATOR;
        if (minOk == 0) revert ZeroAmount();
        if (param.destAmount < minOk) revert Slippage(param.destAmount, minOk);

        _safeApprove(USDT, ACROSS_PROTOCOL, usdtAmt);
        received = _oftSendCall(sp.dstEid, sp.to, sp.amountLD, sp.minAmountLD, param.nativeFee, msg.sender);
        _safeApprove(USDT, ACROSS_PROTOCOL, 0);

        emit Bridge(msg.sender, recipient, USDT, received, param.destChainId);
    }

    function _oftSendParam(SwapParam calldata param, uint256 usdtAmt)
        internal
        pure
        returns (SendParam memory sp)
    {
        sp.dstEid = dstEidOf(param.destChainId);
        sp.to = oftTo(param.destChainId, param.recipient);
        sp.amountLD = usdtAmt;
        sp.minAmountLD = param.destAmount;
        sp.extraOptions = "";
        sp.composeMsg = "";
        sp.oftCmd = "";
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

    /// @dev UsdtOFT send(SendParam, MessagingFee, refundAddress) payable。
    /// 函数签名: send((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),(uint256,uint256),address)
    /// Selector: 0xc7c7f5b3
    /// MessagingFee 固定 {nativeFee, lzTokenFee:0}；callvalue = nativeFee；refund = msg.sender。
    /// calldata: selector(4) + SendParam offset 0x80(32) + nativeFee(32) + 0(32) + refund(32)
    ///           + SendParam 体(0x140) = 0x1c4
    /// 返回 (MessagingReceipt{guid,nonce,fee}, OFTReceipt{amountSentLD,amountReceivedLD}) 全静态 6 word。
    /// amountReceivedLD 在偏移 0xa0。
    function _oftSendCall(
        uint32 dstEid,
        bytes32 to,
        uint256 amountLD,
        uint256 minAmountLD,
        uint256 nativeFee,
        address refund
    ) internal returns (uint256 amountReceivedLD) {
        address oft = ACROSS_PROTOCOL;
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
        _oftWriteSendParamBody(body, dstEid, to, amountLD, minAmountLD);
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
            amountReceivedLD := mload(add(ptr, 0xa0))
        }
    }

    function _bridgeUsdtAmount(SwapParam calldata param) internal view returns (uint256) {
        uint256 fee = _quoteFee(param.amountIn, param.methodType, param.swapFee);
        if (fee > param.amountIn) revert FeeExceedsAmount(fee, param.amountIn);
        uint256 netIn = param.amountIn - fee;
        uint8 route = routeOf(param.methodType);
        if (route == ROUTE_BRIDGE) return netIn;
        return _getAmountOut(param.swapType, param.tokenIn, param.tokenOut, netIn);
    }

    function _bridgeUsdtAmountQuoted(SwapParam calldata param) internal view returns (uint256) {
        uint8 route = routeOf(param.methodType);
        _assertRoute(param, route);
        if (route == ROUTE_SWAP) {
            uint256 fee = _quoteFee(param.amountIn, param.methodType, param.swapFee);
            if (fee > param.amountIn) revert FeeExceedsAmount(fee, param.amountIn);
            return _getAmountOut(param.swapType, param.tokenIn, param.tokenOut, param.amountIn - fee);
        }
        uint256 usdtAmt = _bridgeUsdtAmount(param);
        SendParam memory sp = _oftSendParam(param, usdtAmt);
        return _oftQuoteReceived(sp.dstEid, sp.to, sp.amountLD, sp.minAmountLD);
    }

    function _assertRoute(SwapParam calldata param, uint8 route) private view {
        if (route > ROUTE_BRIDGE) revert InvalidMethodType(param.methodType);
        if (param.destToken != address(0) && param.destToken != USDT) revert BridgeTokenMustBeUsdt();
        if (route == ROUTE_SWAP) {
            _assertListed(param.tokenIn);
            _assertListed(param.tokenOut);
            return;
        }
        dstEidOf(param.destChainId);
        if (param.recipient == address(0)) revert ZeroAddress();
        if (route == ROUTE_BRIDGE) {
            if (param.tokenIn != USDT) revert BridgeTokenMustBeUsdt();
            return;
        }
        _assertListed(param.tokenIn);
        if (param.tokenOut != USDT) revert BridgeTokenMustBeUsdt();
    }

    /// @dev 免费=0；固定=`swapFee`；比例=`amountIn * feeRate / 1e6`
    function _quoteFee(uint256 amountIn, uint8 methodType, uint208 swapFee) internal view returns (uint256 fee) {
        uint8 mode = feeModeOf(methodType);
        if (mode == FEE_FREE) return 0;
        if (mode == FEE_FIXED) return uint256(swapFee);
        if (mode == FEE_RATE) {
            uint24 rate = _feeInfo.feeRate;
            if (rate == 0) return 0;
            fee = (amountIn * rate) / FEE_DENOMINATOR;
            if (swapFee != 0 && fee > uint256(swapFee)) revert FeeExceedsAmount(fee, swapFee);
            return fee;
        }
        revert InvalidMethodType(methodType);
    }

    /// @dev 从 amountIn 划出协议费并留在本合约，返回进入兑换/转出的净额。
    function _chargeFee(
        address token,
        uint256 amountIn,
        uint8 methodType,
        uint208 swapFee
    ) internal returns (uint256 netIn) {
        uint8 mode = feeModeOf(methodType);
        uint256 fee = _quoteFee(amountIn, methodType, swapFee);
        if (fee > amountIn) revert FeeExceedsAmount(fee, amountIn);
        if (fee != 0) {
            emit FeeCharged(token, address(this), fee, mode);
        }
        return amountIn - fee;
    }

    function _coins(address pool, address tokenIn, address tokenOut) internal view returns (int128 i, int128 j) {
        i = _index(pool, tokenIn);
        j = _index(pool, tokenOut);
        if (i == j) revert SameToken();
    }

    /// @dev 读池子 `coins(uint256)`，selector `0xc6610657`。最多 3 币（3pool）；NG 在 k=2 失败即停。
    function _index(address pool, address token) internal view returns (int128) {
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
                return int128(int256(k));
            }
        }
        revert UnknownToken(token);
    }

    function _assertListed(address token) private view {
        if (!_isListed(token)) revert UnknownToken(token);
    }

    function _isListed(address token) private view returns (bool) {
        return token == DAI || token == USDC || token == USDT || token == PYUSD || token == CRVUSD || token == RLUSD;
    }

    function _is3(address token) private view returns (bool) {
        return token == DAI || token == USDC || token == USDT;
    }

    function _orDefault(address value, address fallbackAddr) private pure returns (address) {
        return value == address(0) ? fallbackAddr : value;
    }

    function _pair(address a, address b, address x, address y) private pure returns (bool) {
        return (a == x && b == y) || (a == y && b == x);
    }

    function _ethTransfer(address recipient, uint256 amount) internal {
        bool failed;
        assembly {
            failed := iszero(call(gas(), recipient, amount, 0, 0, 0, 0))
        }
        if (failed) revert ClaimFailed();
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
        if (amount != 0) {
            _tokenApprove(token, spender, 0);
        }
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
