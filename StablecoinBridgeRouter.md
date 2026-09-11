# StablecoinBridgeRouter

Solidity `>=0.8.28`。

单笔路由：从调用方拉入 `tokenIn`（仅列出的稳定币），先划出协议费并留在本合约，再做 Curve 兑换或 UsdtOFT 跨链。失败则整笔回滚；累计手续费与滞留资产由 owner `claimFee` 提出。

跨链（route 1/2）必须先 `quoteBridge`，把返回的 `nativeFee`、`minAmountLD` 写入 `SwapParam.nativeFee` / `destAmount`，再 `execute{value: nativeFee}`。`execute` **不再**链上 `quoteSend`；`msg.value` 必须 **等于** `nativeFee`（只兑必须为 0），合约 **不退** 多余 ETH。

主网已部署 Router：`0x079484864473dd4Fa291064723F3b307058778Ee`。immutable 字段 `ACROSS_PROTOCOL` 实际是主网 UsdtOFT `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0`（USDT0 Legacy Mesh），不是 Across SpokePool。

---

## 1. 业务架构

本合约是调用方与外部市场之间的一层：收费、选池、兑换、转出。用户本金当笔进出；协议费留在合约内直至管理员提取。

```
                    ┌─────────────┐
                    │    owner    │  setOwner / setFeeInfo / claimFee
                    └──────┬──────┘
                           │
调用方 ──approve──► ┌──────▼──────────────────────────┐
                    │     StablecoinBridgeRouter      │
                    │  拉币 → 划费留存 → 兑换和/或转出 │
                    └───┬──────────┬──────────┬───────┘
                        │          │          │
                        ▼          ▼          ▼
                   手续费留存    Curve 池   UsdtOFT.send
                   （claimFee）  （兑换）    （quote 参数原样传入）
                        │          │
                        │          ▼
                        │     recipient / 目的链 OFT to
```

| 角色 | 职责 |
|---|---|
| 调用方 `msg.sender` | 事先 `approve`；跨链先 `quoteBridge` 填 `nativeFee`/`destAmount`，再 `execute{value: nativeFee}` |
| owner | 改管理员、写 `FeeInfo`、把本合约内累计手续费与滞留资产 `claimFee` 到 `feeRecipient` |
| `feeRecipient` | 仅 `claimFee` 时的收款地址；交易过程不向外转手续费 |
| Curve 3pool / NG | 同链稳定币兑换 |
| `ACROSS_PROTOCOL` | 主网 UsdtOFT（LayerZero V2）；`send` 跨链 USDT，仅 ETH→波场 |

合约内部按职责拆开：

```
StablecoinBridgeRouter
├── 编码：routeOf / feeModeOf / encodeMethodType
├── 选池：poolOf / defaultSwapType / coins 下标
├── 报价：quoteBridge / quoteBridgeNativeFee / getAmountOut
├── 执行：execute（payable + nonReentrant）
│     ├── _chargeFee
│     ├── _curveSwap（3pool / NG exchange）
│     └── _oftSend（传入 destAmount / nativeFee；send 前再 quoteOFT 校验 99%）
├── 治理：owner / setFeeInfo / claimFee（nonReentrant）
└── 代币：汇编 transfer / transferFrom / approve / balanceOf；receive/fallback payable
```

池地址、代币地址、`ACROSS_PROTOCOL` 均为 `immutable`，构造时写入（字段为 0 则用以太坊主网 `DEFAULT_*`）。链上可变状态只有 `_owner`、`_feeInfo`、重入锁 `_status`。

---

## 2. 业务能力

覆盖三类资金路径，与三种收费方式正交组合。

**路径（`methodType` 低 4 位 `route`）**

| 值 | 常量 | 业务含义 | 资金终点 |
|---|---|---|---|
| 0 | `ROUTE_SWAP`（同 `ROUTE_SWAP_ONLY`） | 同链兑换 | `tokenOut` 给 `recipient` |
| 1 | `ROUTE_SWAP_BRIDGE` | Curve 兑成 USDT 后 UsdtOFT.send | 目的链 OFT 收款人 |
| 2 | `ROUTE_BRIDGE` | tokenIn 必须是 USDT，直接 send | 目的链 OFT 收款人 |

**收费（`methodType` 高 4 位 `feeMode`）**

三种模式都在 Curve / 转出 **之前**、从 **`tokenIn` 全额** 中划出净额。手续费**留在本合约**，不转给 `feeRecipient`；由 owner 日后 `claimFee` 提出。

| 值 | 常量 | 计费 |
|---|---|---|
| 0 | `FEE_FREE` | 0 |
| 1 | `FEE_FIXED` | 本笔 `swapFee`（tokenIn 最小单位） |
| 2 | `FEE_RATE` | `amountIn * FeeInfo.feeRate / 1e6`（`MAX_FEE_RATE=1000`，即千分之一） |

比例模式下若 `swapFee ≠ 0`，表示硬上限：算出的手续费 **大于** `swapFee` 则 `FeeExceedsAmount`，**不会**自动压到上限。

`methodType = route | (feeMode << 4)`。预组常量：`METHOD_SWAP_FREE=0x00`、`METHOD_SWAP_FIXED=0x10`、`METHOD_SWAP_RATE=0x20`、`METHOD_SWAP_BRIDGE_FREE=0x01`、`METHOD_SWAP_BRIDGE_FIXED=0x11`、`METHOD_SWAP_BRIDGE_RATE=0x21`、`METHOD_BRIDGE_FREE=0x02`、`METHOD_BRIDGE_FIXED=0x12`、`METHOD_BRIDGE_RATE=0x22`。

典型业务组合：

| 场景 | methodType | 说明 |
|---|---|---|
| 本链 USDT→USDC，不收费 | `0x00` | 3pool 兑换后打给 `recipient` |
| 本链兑换，按比例收费 | `0x20` | 先从 tokenIn 扣费，净额再兑；`swapFee=0` 不设上限 |
| 兑 USDT 后跨链 / 仅跨链 | `0x01` / `0x02` 等 | 先 `quoteBridge` 再带 ETH 调 `execute` |

---

## 3. `SwapParam`

槽 0 打包：`uint8 swapType` + `uint8 methodType` + `uint32 fillDeadline` + `uint208 swapFee`。

| 字段 | 含义 |
|---|---|
| `swapType` | Curve 池；仅 route 0/1 需要兑换时有意义 |
| `methodType` | `route \| (feeMode << 4)` |
| `fillDeadline` | **未使用** |
| `swapFee` | 固定费金额；比例模式下非 0 则为手续费硬上限 |
| `tokenIn` / `tokenOut` | 拉入 / 兑出币；须在白名单 |
| `recipient` | 只兑：`0` 视为 `msg.sender`。跨链：**必须非 0**，填去掉 `41` 的波场 20 字节体 |
| `amountIn` | 拉入数量（含手续费） |
| `minAmountOut` | Curve 兑出下限（route 0/1） |
| `destChainId` | 仅波场：`30420`（LZ EID）或 `728126428` |
| `destToken` | 非 0 时必须是 USDT |
| `destAmount` | 写入询价 `minAmountLD`；成交时须 ≥ `quoteOFT.amountReceivedLD * 9900/10000` |
| `nativeFee` | 询价 `quoteSend(..., false)` 的 Wei；跨链时 `msg.value` 必须相等 |

---

## 4. 业务流程

### 4.1 调用前（同链）

1. 确定 `tokenIn` / `tokenOut` / 数量。
2. 选 `swapType`。不要盲信 `defaultSwapType`（USDC↔USDT 总会给 3pool）。用 **`eth_call` 预执行比较各池报价**，再写入真正的 `execute`（见 5.2）。经验上小额 NG 更好、大额 3pool 更深，仍以当次 `eth_call` 为准。
3. 选 `route` + `feeMode`，填 `methodType`。
4. 固定费填 `swapFee`；比例费用 `FeeInfo.feeRate`，`swapFee` 保持 0 除非要硬上限。
5. `getAmountOut` 估净兑出，设 `minAmountOut`。
6. `approve(tokenIn, amountIn)` 给 **Router**（不是 UsdtOFT）。
7. route 0：`execute` 且 `msg.value == 0`。route 1/2：见 4.4。

代币须在白名单：DAI / USDC / USDT / PYUSD / crvUSD / RLUSD。

### 4.2 `execute` 主流程

```
approve(Router, amountIn)
        │
[跨链] quoteBridge → 写入 nativeFee、destAmount
        │
execute{value: nativeFee}(SwapParam)
        │
校验 msg.value == (route 0 ? 0 : nativeFee)
拉币 → 划费 → route 0 兑给 recipient
                 route 1 Curve 成 USDT 再 UsdtOFT.send
                 route 2 USDT 直接 send
不退多余 ETH
```

`execute` 与 `claimFee` 均 `nonReentrant`。route 0 / 1 兑换成功发 `Swap`。route 1 / 2 `send` 后发 `Bridge`（`amount` 为目的链预计到账，扣 Mesh 费后）。

### 4.3 Curve 兑换子流程（route 0 / 1）

1. `poolOf(swapType)` 得到池地址；`coins(k)` 解析 `tokenIn`/`tokenOut` 下标（同币 `SameToken`，找不到 `UnknownToken`）。
2. 对池 `approve(tokenIn)`（先置 0 再授权）。
3. 记 `tokenOut` 兑换前余额。
4. 3pool：`exchange(i,j,dx,min_dy)` `0x3df02124`，兑出留在本合约。  
   NG：`exchange(i,j,dx,min_dy,receiver)` `0xddc1f59d`，`receiver` 为本合约。
5. 失败则池子 revert 数据原样冒泡。
6. 兑出量 = 余额差；小于 `minAmountOut` → `Slippage`。
7. 收回对池的授权（approve 0）。
8. route 0：把 `tokenOut` 转给 `recipient`。  
   route 1：本合约持有兑出的 USDT，接着走 4.4。

### 4.4 跨链（对齐 UsdtOFT：quoteOFT + quoteSend → approve → send）

Router 替调用方组 `SendParam` 并代付 `send`。USDT 的 `approve` 对象是 **Router**；Router 再授权 UsdtOFT。

| Etherscan 步骤 | Router |
|---|---|
| 1. T 地址 → hex `41`+20 字节 → 补成 `bytes32` | `oftTo(destChainId, recipient)`；`recipient` 只填去掉 `41` 的 20 字节 |
| 2. `quoteOFT` + `quoteSend(_sendParam, false)` | `quoteBridge`；把 `nativeFee`、`minAmountLD` 写回 `SwapParam` |
| 3. USDT `approve(UsdtOFT, amount)` | 调用方 `approve(Router)`；Router 在 `send` 前授权 OFT |
| 4. `send{value: nativeFee}(同一 _sendParam, {nativeFee, lzTokenFee:0}, refund)` | `execute{value: nativeFee}`；`refundAddress = msg.sender` |

波场 `SendParam.to`：**11 字节 0 + `0x41` + 20 字节地址**（正好 32 字节）。  
手册里「12 字节 0 再拼 21 字节 `41…`」是 33 字节，不能作为 `bytes32`。

`dstEid`：仅波场 `30420`（或 chainId `728126428`）。其它 `destChainId` → `UnknownDestChain`。`extraOptions` / `composeMsg` / `oftCmd` 均为空 `0x`。

UsdtOFT 调用全部内联汇编（无接口 import）：`quoteOFT` `0x0d35b415`（`amountReceivedLD` 在返回 `0x80`）；`quoteSend` `0x3b6f743b`（只取 `nativeFee`）；`send` `0xc7c7f5b3`（收到量在返回 `0xa0`）。

### 4.5 报价与成交校验

| 方法 | 业务含义 |
|---|---|
| `quoteBridge` | 返回与 `send` 相同结构的 `SendParam`、`nativeFee`、`minAmountLD` |
| `quoteBridgeNativeFee` | 只返回 `nativeFee` |
| `getAmountOut` | route 0：扣费后 `get_dy`；route 1/2：OFT `amountReceivedLD` |

成交时（`_oftSend`）：

1. 若 `destAmount >` 实际 USDT 数量，把发给 OFT 的 `minAmountLD` **夹到** `amountLD`（避免 1 wei `get_dy` 漂移触发 OFT Slippage）。
2. 再 `quoteOFT`；要求调用方传入的 `destAmount` ≥ 该次 `amountReceivedLD * OFT_MIN_BPS / 10000`（99%）。低于则 `Slippage`。
3. `destAmount = 0` → `ZeroAmount`。

跨链必须填写 `recipient`。`msg.value` 必须等于 `nativeFee`（只兑必须为 0）。多付、少付都 `NativeFeeMismatch`。OFT 若退手续费，退到 `refundAddress`（`msg.sender`）。滞留在本合约的 ETH 只能由 owner `claimFee(address(0), …)` 提出。

### 4.6 治理与归集

部署：`constructor(initOwner, AddressConfig)`。主网可将 `AddressConfig` 全 0。其它链传入该链池、代币与 UsdtOFT 地址。

1. `setFeeInfo`：写比例费率（`≤1000`，分母 1e6）和 `feeRecipient`。`feeRate≠0` 时须带 `feeRecipient`。固定费金额不在这里设，在每笔 `swapFee`。
2. `claimFee(token, amount)`：把本合约持有的 ERC20（含累计手续费；`token=0` 为 ETH）转到 `feeRecipient`。`amount==1` 表示全部余额；`0` → `ZeroAmount`；超过余额 → `FeeExceedsAmount`。`feeRecipient` 为 0 时不可 claim。
3. `setOwner`：移交管理员。

`receive` / `fallback` 均为 `payable`（可收 ETH），提取仍走 `claimFee`。

---

## 5. Curve 池（`swapType`）

| swapType | 池 | 交易对 | 默认主网地址 |
|---|---|---|---|
| 0 | 3pool | DAI / USDC / USDT | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` |
| 1 | NG USDC/USDT | **小额** USDC↔USDT（协议费率更低、汇率更好）；调用方显式 `swapType=1` | `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85` |
| 2 | NG PYUSD/USDC | | `0x383E6b4437b59fff47B619CBA855CA29342A8559` |
| 3 | NG crvUSD/USDC | | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` |
| 4 | NG USDC/RLUSD | | `0xD001aE433f254283FeCE51d4ACcE8c53263aa186` |

`defaultSwapType` 只看币种、不看金额：DAI/USDC/USDT 一律返回 3pool；PYUSD/crvUSD/RLUSD 对 USDC 走对应 NG。USDC↔USDT 不要依赖这个默认值，应 **`eth_call` 对各 `swapType` 询价后取优**（见 5.2）。币种索引运行时读 `coins(i)`，不写死 NG 下标。

### 5.1 主网 fork 实测（USDT→USDC，免 Router 协议费）

损耗 = `1 - 兑出USDC/进池USDT`，单位 bps（万分之一）。数字来自当时主网 fork 成交，池状态变了会变。

| 路径 | 进池 USDT | 出 USDC | 相对 1:1 损耗 |
|---|---|---|---|
| NG 小额 | 10 | 9.996699 | 约 3.30 bps |
| NG 大额 | 10000 | 9996.877305 | 约 3.12 bps |
| 3pool 大额 | 10000 | 9995.850827 | 约 4.15 bps |

结论：

- **相对 3pool，NG 更优**（协议费率更低），所以小额应走 NG，而不是「金额小汇率就一定更好」。
- **同是 NG**，10 与 10000 几乎一样；这次 10000 还略好（冲击仍很小）。
- Router 再加万分之一比例费时，总损耗约再加 1 bps：NG 小额约 4.30 bps（10→9.995699），3pool 大额约 5.15 bps（10000→9994.851242）。

USDC→USDT 方向这次 NG/3pool 净额都能略多于本金（池内失衡），比的仍是池费率。大额应改走 3pool 是为了深度，避免 NG 浅池被大单打穿，不是因为 3pool 费率更低。

### 5.2 用 `eth_call` 比较池价再选 `swapType`

合约**不会**按金额自动选池。调用方在发交易前对同一笔 `SwapParam`（只改 `swapType`）做只读预执行，比较返回的兑出量，再把胜出的 `swapType` 交给真正的 `execute`。

**推荐：`eth_call` `getAmountOut`**

- 不花 gas、不需要用户已 `approve`、不改状态。
- 只兑（route 0）：返回扣协议费后的 Curve `get_dy`。
- 兑后跨链（route 1）：返回扣费、兑成 USDT 后再 `quoteOFT` 的目的链预计到账，同样可用来比 3pool vs NG。
- 其它字段保持一致：`tokenIn` / `tokenOut` / `amountIn` / `methodType` / `swapFee` / `recipient` / `destChainId`。USDC↔USDT 至少打 `swapType=0` 和 `1` 各一次。
- 取 **`getAmountOut` 更大** 的池。若两者接近但金额很大，可仍选 3pool，避免 NG 浅池被打穿（报价好、成交滑点却爆）。

RPC 形态：`eth_call`，`to` 为本 Router，`data` 为 `getAmountOut(SwapParam)` 编码；`from` 任意即可。可对 `0`、`1` 并行两个 `eth_call`。

**可选：`eth_call` `execute`（仿真成交）**

- 返回值即本笔 `outAmount`（只兑为 `tokenOut`；跨链为 OFT 预计到账）。
- 会走拉币 / 授权 / `exchange` / `send` 的校验，因此仿真时要用 **state override**：给 `from` 足够的 `tokenIn` 余额和对 Router 的 allowance；跨链再带上 `value = nativeFee`（可先 `eth_call` `quoteBridge` 取费）。
- 适合在 `getAmountOut` 很接近、或要核对 `minAmountOut` / `destAmount` 时复核。节点若不支持 override，只用 `getAmountOut`。

**跨链两步仍不变：** 先对选定的 `swapType` `quoteBridge`（或同样 `eth_call`），把 `nativeFee`、`minAmountLD` 写回，再 `execute{value: nativeFee}`。询价到发交易之间池会变，`minAmountOut` 按报价留滑点。

---

## 6. 外部调用

不 import Curve / 跨链合约接口，按 selector 用内联汇编 `staticcall` / `call`。

| 依赖 | 默认地址 | 当前行为 |
|---|---|---|
| Curve 3pool | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` | `get_dy` `0x5e0d443f`；`exchange` `0x3df02124` |
| Curve NG 2pool | 上表 1–4 | `get_dy`；`exchange`+receiver `0xddc1f59d` |
| `ACROSS_PROTOCOL` | `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0` | UsdtOFT `quoteOFT` / `quoteSend` / `send`（仅 ETH→波场） |

ERC20 / ETH 同样用汇编打包 selector。`approve` 先置 0，兼容 USDT。ERC20 只检查 call 成功（USDT 空返回视为成功）。

---

## 7. 状态、权限与事件

| 状态 | 可变性 | 谁改 |
|---|---|---|
| 池 / 代币 / ACROSS_PROTOCOL | `immutable` | 仅构造 |
| `_owner` | storage | `setOwner` |
| `_feeInfo` | storage | `setFeeInfo` |
| `_status` | storage | 重入锁 |

- `execute`：任意已对本合约授权 `tokenIn` 的地址。
- `setOwner` / `setFeeInfo` / `claimFee`：`onlyOwner`。

| 事件 | 何时 |
|---|---|
| `FeeCharged` | 本笔已划出手续费并留在本合约 |
| `Swap` | Curve 兑换完成（route 1 时 token 仍在本合约，随后 `send`） |
| `Bridge` | UsdtOFT 已 `send`；`amount` 为目的链预计到账 |
| `FeeInfoUpdated` | 更新比例费率或收款地址 |
| `OwnerChanged` | 更换 owner |

自定义错误：`OwnableUnauthorizedAccount`、`OwnableInvalidOwner`、`UnknownToken`、`UnknownPool`、`InvalidMethodType`、`SameToken`、`ZeroAmount`、`Slippage`、`InvalidFeeRate`、`ZeroAddress`、`ExchangeFailed`、`FeeExceedsAmount`、`ClaimFailed`、`ReentrancyGuardReentrantCall`、`UnknownDestChain`、`BridgeTokenMustBeUsdt`、`NativeFeeMismatch`。

---

## 8. 边界

- 协议费与兑换 / `send` 在同一笔 `execute` 内，失败一并回滚。
- `send` 之后不再跟踪；资金按 UsdtOFT / LayerZero / Mesh 规则处理。
- 非 6 位小数代币可用，`swapFee` 按该币最小单位解释。
- 本合约无签名与 nonce，重放防护由调用方自行保证。
- `claimFee` 的 `amount==1` 表示全部，无法精确提取 1 个最小单位。
- 3pool 兑出可能比询价少 1 wei；本地源码会把 OFT `minAmountLD` 夹到 `amountLD`。若链上字节码较旧，fork 测试里 3pool SwapBridge 仍可能 OFT `Slippage`。
