# StablecoinBridgeQuery

只读查询合约，源码 [`StablecoinBridgeQuery.sol`](./StablecoinBridgeQuery.sol)。`pragma solidity >=0.8.28`。

与主网 [`StablecoinBridgeRouter`](./StablecoinBridgeRouter.md) **同一套报价规则**（2 bps、同一批 Curve 池、同一 UsdtOFT `quoteOFT` / `quoteSend`、同一波场 `oftTo` 编码），但：

- **无状态**：无 owner、无余额、无重入锁
- **不拉币、不 `execute`**：不能成交
- **查询失败不 `revert`**：非法参数 / 外部 `staticcall` 失败一律返回 `0` / `false` / `address(0)` / `bytes32(0)`

成交仍走 Router：[`0xcda2c4eaC941F9d4b6003bCeEbF3d2C5805AD121`](https://etherscan.io/address/0xcda2c4eac941f9d4b6003bceebf3d2c5805ad121)。前端成交流程见 [StablecoinBridgeRouter.frontend.md](./StablecoinBridgeRouter.frontend.md)；总览见 [StablecoinBridge.md](./StablecoinBridge.md)。

本合约部署后用 `eth_call` 即可。未部署时也可对已验证源码做 `eth_call` 到任意地址（无存储依赖），或本地 fork 部署。

---

## 1. 用来做什么

| 场景 | 调哪个 |
| --- | --- |
| 与 Router 同参询价（单池） | `quote` |
| 对 swapType `0..4` 扫一遍，取 `outAmount` 最大的池 | `quoteAll` |
| 只看扣费后 Curve `get_dy`（不含 OFT） | `getAmountOut` |
| 发 `execute` 前核对 `allowance(holder, ROUTER)` | `routerAllowance` |
| 查余额（`token=0` 为 ETH） | `tokenBalance` |
| 算手续费 / 净入金 | `feeOf` / `netInOf` |
| 池地址、币下标、池内 `coins` | `poolOf` / `tokenIndex` / `poolCoins` |
| 波场 EID、OFT `to` | `dstEidOf` / `oftTo` |
| 代币是否在白名单 | `isListed` |

**不要**用本合约替代 Router 成交。`quote` 的 `outAmount` / `nativeFee` 仍按前端文档填 `execute`：`minAmountLD = outAmount * (10000 - oftToleranceBps) / 10000`，`msg.value = nativeFee`。

---

## 2. 与 Router 的差异

| | Router `quote` | Query `quote` / `quoteAll` |
| --- | --- | --- |
| 非法 `methodType` / 未知币 / 非波场 / `recipient=0`（跨链） | `revert`（`InvalidMethodType` / `UnknownToken` / `ZeroAddress` / `BridgeTokenMustBeUsdt`） | `(0, 0)` |
| Curve / OFT `staticcall` 失败 | 视实现可能得到 0 或 revert | `0` |
| `quoteAll` | 无 | 有 |
| `execute` / `claimFee` | 有 | **无** |
| 协议费、池、OFT、`oftTo`（`11×0 + 0x41 + 20 字节`） | 相同 | 相同 |

`methodType=2` 不走路：`quoteAll` 只填 `outs[0]`，`bestSwapType=0`。

---

## 3. 常量（与 Router 对齐，主网写死）

| 常量 | 值 |
| --- | --- |
| `PROTOCOL_FEE_BPS` | `2`（`amountIn * 2 / 10000`） |
| `LZ_EID_TRON` | `30420` |
| `TRON_CHAIN_ID` | `728126428`（`destChainId` 填二者之一） |
| `NOT_FOUND` | `type(uint256).max`（`tokenIndex` 找不到） |
| `ROUTER` | `0xcda2c4eaC941F9d4b6003bCeEbF3d2C5805AD121` |
| `ACROSS_PROTOCOL` | `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0`（主网 UsdtOFT，历史命名） |

| `swapType` | 常量 | 池 |
| --- | --- | --- |
| `0` | `TYPE_3POOL` | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` DAI / USDC / USDT |
| `1` | `TYPE_USDC_USDT` | `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85` NG |
| `2` | `TYPE_PYUSD_USDC` | `0x383E6b4437b59fff47B619CBA855CA29342A8559` |
| `3` | `TYPE_CRVUSD_USDC` | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` |
| `4` | `TYPE_USDC_RLUSD` | `0xD001aE433f254283FeCE51d4ACcE8c53263aa186` |

| 代币 | 地址 | decimals |
| --- | --- | --- |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | 18 |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 |
| PYUSD | `0x6c3ea9036406852006290770BEdFcAbA0e23A0e8` | 6 |
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` | 18 |
| RLUSD | `0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD` | 18 |

| `methodType` | 含义 | `quote` 返回 |
| --- | --- | --- |
| `0` `METHOD_SWAP` | 只兑 | `outAmount` = 扣费后 `get_dy`，`nativeFee=0` |
| `1` `METHOD_SWAP_BRIDGE` | 兑成 USDT 再跨 | `outAmount` = OFT `amountReceivedLD`，`nativeFee` = `quoteSend` |
| `2` `METHOD_BRIDGE` | USDT 直跨 | 同上；`tokenIn` 须为 USDT |

`destToken`：`0` 跳过；非 0 必须是本链 USDT，否则 `quote` 返回 `(0,0)`。

---

## 4. 报价路径

```
amountIn
   │
   ├─ feeOf  = amountIn * 2 / 10000     （与 Router 划费一致）
   └─ netIn  = amountIn - fee
         │
         ├─ methodType=0  → Curve get_dy(netIn) → outAmount，nativeFee=0
         ├─ methodType=1  → Curve get_dy → USDT → quoteOFT / quoteSend
         └─ methodType=2  → netIn 当 USDT → quoteOFT / quoteSend
```

跨链 `quoteOFT` 的 `minAmountLD` 在查询里传 **0**（只报「当前能到账多少」）。成交时由调用方把 `outAmount` 链下打折写入 Router `execute.minAmountLD`。

`oftTo(destChainId, recipient)`：`bytes32 = 11 字节 0 + 0x41 + recipient(20)`。非法链或 `recipient==0` → `0`。

---

## 5. 外部调用（均为 `staticcall`）

| 目标 | selector | 用途 |
| --- | --- | --- |
| Curve `get_dy(int128,int128,uint256)` | `0x5e0d443f` | 兑出 |
| Curve `coins(uint256)` | `0xc6610657` | 下标 / `poolCoins`；NG 无第 3 币则该位为 0 |
| UsdtOFT `quoteOFT` | `0x0d35b415` | 取返回第 5 个 word（offset `0x80`）= `amountReceivedLD` |
| UsdtOFT `quoteSend` | `0x3b6f743b` | 原生费（`payInLzToken=false`） |
| ERC20 `balanceOf` | `0x70a08231` | `tokenBalance` |
| ERC20 `allowance` | `0xdd62ed3e` | `routerAllowance(holder, ROUTER)` |

任一失败 → 该函数返回 0，不向上 revert。

---

## 6. 函数与 selector

| selector | 签名 | 失败时 |
| --- | --- | --- |
| `0xaf9e3a36` | `feeOf(uint256) → uint256` | 纯函数，无失败 |
| `0x5be5223a` | `netInOf(uint256) → uint256` | 纯函数 |
| `0xf794062e` | `isListed(address) → bool` | 未列出 → `false` |
| `0x83966021` | `poolOf(uint256) → address` | 未知 `swapType` → `0` |
| `0xa8621df8` | `dstEidOf(uint256) → uint32` | 非波场 → `0` |
| `0xa9bdefe1` | `oftTo(uint256,address) → bytes32` | 非法 → `0` |
| `0xfd4ae05c` | `tokenIndex(uint256,address) → uint256` | 找不到 → `NOT_FOUND` |
| `0x782ac01c` | `poolCoins(uint256) → (address,address,address)` | 未知池 → 全 0 |
| `0x8fb64308` | `getAmountOut(uint256,address,address,uint256) → uint256` | 未列出 / 同币 / 无池 → `0` |
| `0x59237783` | `quote(...) → (uint256 outAmount, uint256 nativeFee)` | `(0, 0)` |
| `0xe26ae9a6` | `quoteAll(...) → (uint256[5] outs, uint256 nativeFee, uint256 bestSwapType, uint256 bestOut)` | 各槽 0 |
| `0x1049334f` | `tokenBalance(address,address) → uint256` | `0` |
| `0x741f8980` | `routerAllowance(address,address) → uint256` | `0` |

`quote` / `quoteAll` 参数顺序与 Router `quote` 相同（`quoteAll` 无 `swapType`，内部扫 0..4）：

`methodType, tokenIn, tokenOut, recipient, amountIn, destChainId, destToken`（`quote` 最前面多 `swapType`）。

---

## 7. 前端用法（建议）

```ts
export const QUERY_ABI = [
  "function quote(uint256 swapType, uint256 methodType, address tokenIn, address tokenOut, address recipient, uint256 amountIn, uint256 destChainId, address destToken) view returns (uint256 outAmount, uint256 nativeFee)",
  "function quoteAll(uint256 methodType, address tokenIn, address tokenOut, address recipient, uint256 amountIn, uint256 destChainId, address destToken) view returns (uint256[5] outs, uint256 nativeFee, uint256 bestSwapType, uint256 bestOut)",
  "function getAmountOut(uint256 swapType, address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256)",
  "function routerAllowance(address token, address holder) view returns (uint256)",
  "function tokenBalance(address token, address holder) view returns (uint256)",
  "function feeOf(uint256 amountIn) view returns (uint256)",
  "function netInOf(uint256 amountIn) view returns (uint256)",
  "function isListed(address token) view returns (bool)",
  "function poolOf(uint256 swapType) view returns (address)",
  "function oftTo(uint256 destChainId, address recipient) view returns (bytes32)",
] as const;
```

1. 只兑 / 兑后跨：先 `quoteAll`，用 `bestSwapType` 填 Router `execute.swapType`；`bestOut==0` 视为无路，不要发交易。
2. 只跨（`methodType=2`）：直接 `quote(..., 2, USDT, …)`；`quoteAll` 不会比较池。
3. `routerAllowance(tokenIn, wallet) < amountIn` 时先 `approve(ROUTER)`。
4. `outAmount==0` 或跨链 `nativeFee==0`：**不要**当「免费跨链」，这是查询失败。
5. UI「滑点」只展示 Curve 侧；`oftToleranceBps` 单独打 `minAmountLD`。

---

## 8. 无 custom error

本合约不声明 `error`。读失败靠返回值判断，不要按 Router selector 表解码本合约的 revert（正常路径不应 revert）。
