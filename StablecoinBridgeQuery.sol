// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.28;

/// @title 稳定币路由只读查询工具
/// @notice 与 `StablecoinBridgeRouter` 同一套报价与参数规则，无状态、不拉币、不 `execute`。
/// @dev 供 `eth_call`：比池、扣 2 bps 后 Curve `get_dy`、UsdtOFT `quoteOFT`/`quoteSend`。
///      成交仍走 Router 主网 [`0xcda2c4eaC941F9d4b6003bCeEbF3d2C5805AD121`](https://etherscan.io/address/0xcda2c4eac941f9d4b6003bceebf3d2c5805ad121)。
contract StablecoinBridgeQuery {
    uint256 public constant PROTOCOL_FEE_BPS = 2;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint32 public constant LZ_EID_TRON = 30420;
    uint256 public constant TRON_CHAIN_ID = 728126428;

    uint256 public constant TYPE_3POOL = 0;
    uint256 public constant TYPE_USDC_USDT = 1;
    uint256 public constant TYPE_PYUSD_USDC = 2;
    uint256 public constant TYPE_CRVUSD_USDC = 3;
    uint256 public constant TYPE_USDC_RLUSD = 4;

    uint256 public constant METHOD_SWAP = 0;
    uint256 public constant METHOD_SWAP_BRIDGE = 1;
    uint256 public constant METHOD_BRIDGE = 2;

    address public constant ROUTER = 0xcda2c4eaC941F9d4b6003bCeEbF3d2C5805AD121;
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

    error UnknownToken(address token);
    error UnknownPool(uint256 swapType);
    error InvalidMethodType(uint256 methodType);
    error SameToken();
    error ExchangeFailed();
    error UnknownDestChain(uint256 destChainId);
    error BridgeTokenMustBeUsdt();
    error ZeroAddress();

    /// @notice `amountIn * 2 / 10000`（与 Router 划费一致）
    function feeOf(uint256 amountIn) public pure returns (uint256) {
        return (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
    }

    /// @notice 扣协议费后进入 Curve / OFT 的净额
    function netInOf(uint256 amountIn) public pure returns (uint256) {
        return amountIn - feeOf(amountIn);
    }

    function isListed(address token) public pure returns (bool) {
        return token == DAI || token == USDC || token == USDT || token == PYUSD || token == CRVUSD || token == RLUSD;
    }

    function poolOf(uint256 swapType) public pure returns (address) {
        if (swapType == TYPE_3POOL) return POOL_3POOL;
        if (swapType == TYPE_USDC_USDT) return POOL_USDC_USDT;
        if (swapType == TYPE_PYUSD_USDC) return POOL_PYUSD_USDC;
        if (swapType == TYPE_CRVUSD_USDC) return POOL_CRVUSD_USDC;
        if (swapType == TYPE_USDC_RLUSD) return POOL_USDC_RLUSD;
        revert UnknownPool(swapType);
    }

    function dstEidOf(uint256 destChainId) public pure returns (uint32) {
        if (destChainId == LZ_EID_TRON || destChainId == TRON_CHAIN_ID) return LZ_EID_TRON;
        revert UnknownDestChain(destChainId);
    }

    /// @notice 波场 OFT `SendParam.to`：`11 字节 0 + 0x41 + recipient(20)`
    function oftTo(uint256 destChainId, address recipient) public pure returns (bytes32) {
        dstEidOf(destChainId);
        if (recipient == address(0)) revert ZeroAddress();
        return bytes32((uint256(0x41) << 160) | uint256(uint160(recipient)));
    }

    /// @notice 池内 `coins` 下标；代币不在该池则 `UnknownToken`
    function tokenIndex(uint256 swapType, address token) external view returns (uint256) {
        return _index(poolOf(swapType), token);
    }

    /// @notice 池 `coins(0..2)`；NG 无第 3 币时对应位为 0
    function poolCoins(uint256 swapType) external view returns (address c0, address c1, address c2) {
        address pool = poolOf(swapType);
        c0 = _coinAt(pool, 0);
        c1 = _coinAt(pool, 1);
        c2 = _coinAt(pool, 2);
    }

    /// @notice 扣费后 Curve `get_dy`（不含 OFT）
    function getAmountOut(
        uint256 swapType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256) {
        if (!isListed(tokenIn)) revert UnknownToken(tokenIn);
        if (!isListed(tokenOut)) revert UnknownToken(tokenOut);
        return _getAmountOut(swapType, tokenIn, tokenOut, netInOf(amountIn));
    }

    /// @notice 与 Router `quote` 同参同返回：只兑 `nativeFee=0`；跨链为 OFT 到账 + `quoteSend` 原生费
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
        uint256 netIn = netInOf(amountIn);
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

    /// @notice 对 swapType 0..4 分别 `quote`，失败记 0；`bestSwapType` 取 `outAmount` 最大者
    /// @dev methodType=2 不走路，只填 `outs[0]`，`bestSwapType=0`
    function quoteAll(
        uint256 methodType,
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 destChainId,
        address destToken
    ) external view returns (uint256[5] memory outs, uint256 nativeFee, uint256 bestSwapType, uint256 bestOut) {
        if (methodType == METHOD_BRIDGE) {
            (bestOut, nativeFee) = this.quote(0, methodType, tokenIn, tokenOut, recipient, amountIn, destChainId, destToken);
            outs[0] = bestOut;
            return (outs, nativeFee, 0, bestOut);
        }
        for (uint256 t; t < 5; ++t) {
            try this.quote(t, methodType, tokenIn, tokenOut, recipient, amountIn, destChainId, destToken) returns (
                uint256 o,
                uint256 f
            ) {
                outs[t] = o;
                if (o > bestOut) {
                    bestOut = o;
                    nativeFee = f;
                    bestSwapType = t;
                }
            } catch {}
        }
    }

    /// @notice ERC20 `balanceOf`；失败为 0。`token==address(0)` 为 ETH 余额
    function tokenBalance(address token, address holder) external view returns (uint256) {
        if (token == address(0)) return holder.balance;
        return _balanceOf(token, holder);
    }

    /// @notice `allowance(holder, ROUTER)`，发 `execute` 前核对授权
    function routerAllowance(address token, address holder) external view returns (uint256 allowed) {
        address spender = ROUTER;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0xdd62ed3e00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), holder)
            mstore(add(ptr, 0x24), spender)
            if staticcall(gas(), token, ptr, 0x44, ptr, 0x20) {
                if iszero(lt(returndatasize(), 32)) {
                    allowed := mload(ptr)
                }
            }
        }
    }

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
            mstore(emptyPointer, 0x5e0d443f00000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), i)
            mstore(add(emptyPointer, 0x24), j)
            mstore(add(emptyPointer, 0x44), amountIn)
            let success := staticcall(gas(), pool, emptyPointer, 0x64, emptyPointer, 0x20)
            failed := or(iszero(success), lt(returndatasize(), 32))
            if iszero(failed) {
                dy := mload(emptyPointer)
            }
        }
        if (failed) revert ExchangeFailed();
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
            if (!isListed(tokenIn)) revert UnknownToken(tokenIn);
            if (!isListed(tokenOut)) revert UnknownToken(tokenOut);
            return;
        }
        dstEidOf(destChainId);
        if (recipient == address(0)) revert ZeroAddress();
        if (methodType == METHOD_BRIDGE) {
            if (tokenIn != USDT) revert BridgeTokenMustBeUsdt();
            return;
        }
        if (!isListed(tokenIn)) revert UnknownToken(tokenIn);
        if (tokenOut != USDT) revert BridgeTokenMustBeUsdt();
    }

    function _coinAt(address pool, uint256 k) internal view returns (address coin) {
        bool ok;
        assembly {
            let emptyPointer := mload(0x40)
            mstore(emptyPointer, 0xc661065700000000000000000000000000000000000000000000000000000000)
            mstore(add(emptyPointer, 0x04), k)
            ok := staticcall(gas(), pool, emptyPointer, 0x24, emptyPointer, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            if ok {
                coin := mload(emptyPointer)
            }
        }
    }

    function _index(address pool, address token) internal view returns (uint256) {
        for (uint256 k; k < 3; ++k) {
            address coin;
            bool ok;
            assembly {
                let emptyPointer := mload(0x40)
                mstore(emptyPointer, 0xc661065700000000000000000000000000000000000000000000000000000000)
                mstore(add(emptyPointer, 0x04), k)
                ok := staticcall(gas(), pool, emptyPointer, 0x24, emptyPointer, 0x20)
                ok := and(ok, iszero(lt(returndatasize(), 32)))
                if ok {
                    coin := mload(emptyPointer)
                }
            }
            if (!ok) break;
            if (coin == token) return k;
        }
        revert UnknownToken(token);
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
}
