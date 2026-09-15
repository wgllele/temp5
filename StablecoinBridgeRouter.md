# StablecoinBridgeRouter

Solidity `>=0.8.28`。整体路径见 [StablecoinBridge](./StablecoinBridge.md)。前端对接见 [StablecoinBridgeRouter.frontend.md](./StablecoinBridgeRouter.frontend.md)。

单笔路由：从调用方拉入 `tokenIn`（仅列出的稳定币），先划出协议费并留在本合约。三条路径都是 **approve 本合约 + execute**（用户不直接调 Curve / OFT）：

- **methodType=0 只兑不跨**：扣 2 bps，合约内调 Curve，`tokenOut` 留在以太坊；`msg.value` 必须为 0。
- **methodType=1 兑后跨链** / **2 只跨链**：同样先扣 2 bps，再 UsdtOFT 到波场。

失败则整笔回滚；累计手续费与滞留资产由 owner `claimFee` 提出。跨链必须先 `quote`，把返回的 `outAmount`、`nativeFee` 写入 `execute` 的 `destAmount` / `nativeFee`，再 `execute{value: nativeFee}`。`execute` **不再**链上 `quoteSend`；`msg.value` 必须 **等于** `nativeFee`（只兑必须为 0），合约 **不退** 多余 ETH。

主网已部署 Router：`0x4A760E4c0Af6F369E07A97C5ED75E626c1369070`。常量 `ACROSS_PROTOCOL` 实际是主网 UsdtOFT `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0`（USDT0 Legacy Mesh），不是 Across SpokePool。旧地址 `0x0794…` ABI 已废弃。

波场反向入口：[StablecoinBridgeTron](./StablecoinBridgeTron.md) 主网 `TG1tdbbj4crisqw6DZPeApAFnUE72mYh5R`，OFT peer `0x3a08F767…`（`TFG4wBa…`）。

---

## 1. 业务架构

本合约是调用方与外部市场之间的一层：收费、选池、兑换、转出。用户本金当笔进出；协议费留在合约内直至管理员提取。**以太坊不跨链只兑换也走本合约**（`methodType=0`），同样扣 2 bps，不要让用户直对 Curve。

```
                    ┌─────────────┐
                    │    owner    │  setOwner / setFeeRecipient / claimFee
                    └──────┬──────┘
                           │
调用方 ──① approve──►┌────▼────────────────────────────┐
        ──② execute──►│      StablecoinBridgeRouter      │
                      │  拉币 → 划 2 bps 留存（claimFee） │
                      └────┬─────────────────┬──────────┘
                     0 只兑│            1/2 跨链│
                           ▼                    ▼
              ┌────────────────────┐   ┌─────────────────┐
              │ 内调 Curve         │   │ 1：先兑成 USDT   │
              │ 以太坊 tokenOut    │   │ 2：USDT 直发     │
              │ 给 recipient       │   │ UsdtOFT.send    │
              │ 不跨链、已收费     │   └────────┬────────┘
              └────────────────────┘            ▼
                                       波场收款 USDT
```

| 路径 | methodType | 用户签名 | 资金终点 |
|---|---|---|---|
| 以太坊只兑不跨（收费） | `0` | `approve(Router)` + `execute` `msg.value=0` | 以太坊 `tokenOut` |
| 先兑后跨到波场 | `1` | `approve(Router)` + `execute{value: nativeFee}` | 波场 USDT |
| USDT 直跨到波场 | `2` | 同上 | 波场 USDT |

| 角色 | 职责 |
|---|---|
| 调用方 `msg.sender` | 事先 `approve` Router。只兑：`execute` 且 `msg.value=0`。跨链：先 `quote` 填 `nativeFee`/`destAmount`，再 `execute{value: nativeFee}` |
| owner | 改管理员、写 `feeRecipient`、把本合约内累计手续费与滞留资产 `claimFee` 到 `feeRecipient` |
| `feeRecipient` | 仅 `claimFee` 时的收款地址；交易过程不向外转手续费 |
| Curve 3pool / NG | 同链稳定币兑换 |
| `ACROSS_PROTOCOL` | 主网 UsdtOFT（LayerZero V2）；`send` 跨链 USDT，仅 ETH→波场 |

合约内部按职责拆开：

```
StablecoinBridgeRouter
├── 报价：quote（0 只兑 = 扣费后 Curve 净兑出、nativeFee=0；跨链 = OFT 到账 + nativeFee）
├── 执行：execute（0 只兑 value=0 兑给 recipient；1/2 跨链再 send）
├── 治理：owner / setOwner / setFeeRecipient / claimFee
└── 代币：汇编 transfer / transferFrom / approve / balanceOf；receive/fallback payable
```

池地址、代币地址、UsdtOFT 均为 **public constant**（以太坊主网写死）。链上可变状态只有 `_owner`、`_feeRecipient`、重入锁 `_status`。构造函数仅 `initOwner`。

---

## 2. 业务能力

覆盖三类资金路径。协议费固定为 **2 bps**（`amountIn * PROTOCOL_FEE_BPS / 10000`，`PROTOCOL_FEE_BPS=2`），无免费/固定金额模式，`quote`/`execute` 不再传 `feeMode`/`swapFee`。

**路径（`methodType`）**

| 值 | 常量 | 业务含义 | 资金终点 |
|---|---|---|---|
| 0 | `METHOD_SWAP` | 同链兑换 | `tokenOut` 给 `recipient` |
| 1 | `METHOD_SWAP_BRIDGE` | Curve 兑成 USDT 后 UsdtOFT.send | 目的链 OFT 收款人 |
| 2 | `METHOD_BRIDGE` | tokenIn 必须是 USDT，直接 send | 目的链 OFT 收款人 |

**收费**

在 Curve / 转出 **之前**、从 **`tokenIn` 全额** 划出 `amountIn * 2 / 10000`。手续费**留在本合约**，不转给 `feeRecipient`；由 owner 日后 `claimFee` 提出。

典型业务组合：

| 场景 | methodType | 说明 |
|---|---|---|
| 以太坊只兑不跨（收费） | `0` | 先扣 2 bps，净额内调 Curve，`tokenOut` 打给以太坊 `recipient`；不跨链 |
| 兑 USDT 后跨链 / 仅跨链 | `1` / `2` | 同样先扣 2 bps；先 `quote` 再带 ETH 调 `execute` |

---

## 3. `quote` / `execute` 参数（无结构体）

| 字段 | 含义 |
|---|---|
| `swapType` | Curve 池；仅 methodType 0/1 需要兑换时有意义 |
| `methodType` | `0` 只兑 / `1` 兑后跨链 / `2` 只跨链 |
| `tokenIn` / `tokenOut` | 拉入 / 兑出币；须在白名单 |
| `recipient` | 只兑：`0` 视为 `msg.sender`。跨链：**必须非 0**，填去掉 `41` 的波场 20 字节体 |
| `amountIn` | 拉入数量（含手续费） |
| `minAmountOut` | Curve 兑出下限（methodType 0/1） |
| `destChainId` | 仅波场：`30420`（LZ EID）或 `728126428` |
| `destToken` | **不参与发币**。`0` 跳过；非 0 时必须是本链 USDT（断言目的链收 USDT） |
| `destAmount` | 写入询价 `minAmountLD`；成交时须 ≥ `quoteOFT.amountReceivedLD * 9900/10000` |
| `nativeFee` | 询价 `quoteSend(..., false)` 的 Wei；跨链时 `msg.value` 必须相等 |

---

## 4. 业务流程

### 4.1 调用前

1. 确定 `tokenIn` / `tokenOut` / 数量。
2. 选 `swapType`。用 **`eth_call` `quote` 比较各池**，再写入真正的 `execute`（见 5.2）。经验上小额 NG 更好、大额 3pool 更深，仍以当次 `eth_call` 为准。
3. 填 `methodType`（0 只兑 / 1 兑后跨 / 2 只跨）。协议费固定 2 bps。
4. `quote` 估净兑出，设 `minAmountOut`。
5. `approve(tokenIn, amountIn)` 给 **Router**（不是 Curve、不是 UsdtOFT）。
6. methodType 0：见 4.1.1。methodType 1/2：见 4.4。

代币须在白名单：DAI / USDC / USDT / PYUSD / crvUSD / RLUSD。

### 4.1.1 以太坊只兑不跨（methodType=0）

不跨链、只兑换时也必须走本合约并收费。用户只对 Router 签两笔：`approve` + `execute`。Router 先从 `tokenIn` 扣 **2 bps**，再内调 Curve，把 `tokenOut` 打给 `recipient`（`0` 视为 `msg.sender`）。**不要**让用户 `approve` / `exchange` 官方池。

```
quote 比池（只读，nativeFee=0）
        │
tokenIn.approve(Router, amountIn)
        │
execute  methodType=0  value=0
        │
拉币 → 划 2 bps → 内调 Curve → tokenOut 转给以太坊 recipient
```

| 顺序 | 动作 | 签名 |
|---|---|---|
| 0 | `quote` 比池（3pool / NG），记下 `outAmount`；`nativeFee` 为 0 | 否 |
| 1 | `tokenIn.approve(Router, amountIn)` | 是 |
| 2 | `execute methodType=0`：`msg.value=0`，`destAmount=0`，`nativeFee=0` | 是 |

- `minAmountOut` 按 `quote.outAmount` 留滑点。
- 多带 1 wei 也会 `NativeFeeMismatch`。
- `destChainId` / `destToken` 本路径不校验；可填 `728126428` / `0`。

### 4.2 `execute` 主流程

```
approve(Router, amountIn)
        │
[跨链] quote → 写入 nativeFee、destAmount
        │
execute{value: nativeFee}(...)
        │
校验 msg.value == (methodType 0 ? 0 : nativeFee)
拉币 → 划费 → methodType 0 兑给 recipient
                 methodType 1 Curve 成 USDT 再 UsdtOFT.send
                 methodType 2 USDT 直接 send
不退多余 ETH
```

`execute` 与 `claimFee` 均 `nonReentrant`。methodType 0 / 1 兑换成功发 `Swap`。methodType 1 / 2 `send` 后发 `Bridge`（`amount` 为目的链预计到账，扣 Mesh 费后）。

### 4.3 Curve 兑换子流程（methodType 0 / 1）

1. `poolOf(swapType)` 得到池地址；`coins(k)` 解析 `tokenIn`/`tokenOut` 下标（同币 `SameToken`，找不到 `UnknownToken`）。
2. 对池 `approve(tokenIn)`（先置 0 再授权）。
3. 记 `tokenOut` 兑换前余额。
4. 3pool：`exchange(i,j,dx,min_dy)` `0x3df02124`，兑出留在本合约。  
   NG：`exchange(i,j,dx,min_dy,receiver)` `0xddc1f59d`，`receiver` 为本合约。
5. 失败则池子 revert 数据原样冒泡。
6. 兑出量 = 余额差；小于 `minAmountOut` → `Slippage`。
7. 收回对池的授权（approve 0）。
8. methodType 0：把 `tokenOut` 转给 `recipient`。  
   methodType 1：本合约持有兑出的 USDT，接着走 4.4。

### 4.4 跨链（对齐 UsdtOFT：quoteOFT + quoteSend → approve → send）

Router 替调用方组 `SendParam` 并代付 `send`。USDT 的 `approve` 对象是 **Router**；Router 再授权 UsdtOFT。

| Etherscan 步骤 | Router |
|---|---|
| 1. T 地址 → hex `41`+20 字节 → 补成 `bytes32` | `oftTo(destChainId, recipient)`；`recipient` 只填去掉 `41` 的 20 字节 |
| 2. `quoteOFT` + `quoteSend(_sendParam, false)` | `quote`；把 `nativeFee`、`outAmount` 写回 `execute` |
| 3. USDT `approve(UsdtOFT, amount)` | 调用方 `approve(Router)`；Router 在 `send` 前授权 OFT |
| 4. `send{value: nativeFee}(同一 _sendParam, {nativeFee, lzTokenFee:0}, refund)` | `execute{value: nativeFee}`；`refundAddress = msg.sender` |

波场 `SendParam.to`：**11 字节 0 + `0x41` + 20 字节地址**（正好 32 字节）。  
手册里「12 字节 0 再拼 21 字节 `41…`」是 33 字节，不能作为 `bytes32`。

`dstEid`：仅波场 `30420`（或 chainId `728126428`）。其它 `destChainId` → `UnknownDestChain`。`extraOptions` / `composeMsg` / `oftCmd` 均为空 `0x`。

UsdtOFT 调用全部内联汇编（无接口 import）：`quoteOFT` `0x0d35b415`（`amountReceivedLD` 在返回 `0x80`）；`quoteSend` `0x3b6f743b`（只取 `nativeFee`）；`send` `0xc7c7f5b3`（收到量在返回 `0xa0`）。

### 4.5 报价与成交校验

| 方法 | 业务含义 |
|---|---|
| `quote` | 只兑：扣费后 `get_dy`，`nativeFee=0`。跨链：OFT `amountReceivedLD` + `nativeFee` |
| `execute` | 成交 |

成交时（`_oftSend`）：

1. 若 `destAmount >` 实际 USDT 数量，把发给 OFT 的 `minAmountLD` **夹到** `amountLD`（避免 1 wei `get_dy` 漂移触发 OFT Slippage）。
2. 再 `quoteOFT`；要求调用方传入的 `destAmount` ≥ 该次 `amountReceivedLD * OFT_MIN_BPS / 10000`（99%）。低于则 `Slippage`。
3. `destAmount = 0` → `ZeroAmount`。

跨链必须填写 `recipient`。`msg.value` 必须等于 `nativeFee`（只兑必须为 0）。多付、少付都 `NativeFeeMismatch`。OFT 若退手续费，退到 `refundAddress`（`msg.sender`）。滞留在本合约的 ETH 只能由 owner `claimFee(address(0), …)` 提出。

### 4.6 治理与归集

部署：`constructor(initOwner)`。池 / 代币 / UsdtOFT 为常量，不可改。

1. `setFeeRecipient`：写 `claimFee` 收款地址。
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

USDC↔USDT 应 **`eth_call` `quote` 对各 `swapType` 询价后取优**（见 5.2）。币种索引运行时读 `coins(i)`，不写死 NG 下标。

### 5.1 主网 fork 实测（USDT→USDC，进池金额为扣 2 bps 协议费后的净额）

损耗 = `1 - 兑出USDC/进池USDT`，单位 bps。数字来自 2026-09-12 主网 fork（与链上 `0x4A76…` 同逻辑），池状态变了会变。

| 路径 | 进池 USDT | 出 USDC | 仅池损耗 |
|---|---|---|---|
| NG 小额 | 9.998 | 9.997622 | 约 0.38 bps |
| NG 大额 | 9998 | 9997.596787 | 约 0.40 bps |
| 3pool 大额 | 9998 | 9994.825788 | 约 3.17 bps |

相对本金 10 / 10000（含 2 bps 协议费）总损耗约：NG 小额 2.38 bps，NG 大额 2.40 bps，3pool 大额 5.17 bps。

结论：

- **相对 3pool，NG 更优**（协议费率更低），所以小额应走 NG。
- **同是 NG**，10 与 10000 几乎一样。
- 大额改走 3pool 是为了深度，避免 NG 浅池被打穿，不是因为 3pool 费率更低。

USDC→USDT 方向这次 NG/3pool 净额都能略多于进池本金（池内失衡），比的仍是池费率。

### 5.2 用 `eth_call` 比较池价再选 `swapType`

合约**不会**按金额自动选池。调用方在发交易前对同一组参数（只改 `swapType`）`eth_call` `quote`，比较 `outAmount`，再把胜出的 `swapType` 交给真正的 `execute`。

**推荐：`eth_call` `quote`**

- 不花 gas、不需要用户已 `approve`、不改状态。
- 只兑（methodType 0）：返回扣协议费后的 Curve `get_dy`。
- 兑后跨链（methodType 1）：返回扣费、兑成 USDT 后再 `quoteOFT` 的目的链预计到账，同样可用来比 3pool vs NG。
- 其它字段保持一致。USDC↔USDT 至少打 `swapType=0` 和 `1` 各一次。
- 取 **`outAmount` 更大** 的池。若两者接近但金额很大，可仍选 3pool，避免 NG 浅池被打穿。

RPC 形态：`eth_call`，`to` 为本 Router，`data` 为 `quote(...)` 编码。可对 `0`、`1` 并行两个 `eth_call`。

**可选：`eth_call` `execute`（仿真成交）**

- 返回值即本笔 `outAmount`（只兑为 `tokenOut`；跨链为 OFT 预计到账）。
- 会走拉币 / 授权 / `exchange` / `send` 的校验，因此仿真时要用 **state override**：给 `from` 足够的 `tokenIn` 余额和对 Router 的 allowance；跨链再带上 `value = nativeFee`（可先 `eth_call` `quote` 取费）。
- 适合在 `quote` 很接近、或要核对 `minAmountOut` / `destAmount` 时复核。节点若不支持 override，只用 `quote`。

**跨链两步仍不变：** 先对选定的 `swapType` `quote`，把 `nativeFee`、`outAmount`（作 `destAmount`）写回，再 `execute{value: nativeFee}`。询价到发交易之间池会变，`minAmountOut` 按报价留滑点。

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
| 池 / 代币 / ACROSS_PROTOCOL | `constant` | 编译期写死 |
| `_owner` | storage | `setOwner` |
| `_feeRecipient` | storage | `setFeeRecipient` |
| `_status` | storage | 重入锁 |

- `execute`：任意已对本合约授权 `tokenIn` 的地址。
- `setOwner` / `setFeeRecipient` / `claimFee`：`onlyOwner`。

| 事件 | 何时 |
|---|---|
| `FeeCharged` | 本笔已划出手续费并留在本合约 |
| `Swap` | Curve 兑换完成（methodType 1 时 token 仍在本合约，随后 `send`） |
| `Bridge` | UsdtOFT 已 `send`；`amount` 为目的链预计到账 |
| `FeeRecipientUpdated` | 更新 `claimFee` 收款地址 |
| `OwnerChanged` | 更换 owner |

自定义错误：`OwnableUnauthorizedAccount`、`OwnableInvalidOwner`、`UnknownToken`、`UnknownPool`、`InvalidMethodType`、`SameToken`、`ZeroAmount`、`Slippage`、`ZeroAddress`、`ExchangeFailed`、`FeeExceedsAmount`、`ClaimFailed`、`ReentrancyGuardReentrantCall`、`UnknownDestChain`、`BridgeTokenMustBeUsdt`、`NativeFeeMismatch`。

---

## 8. 边界

- 协议费与兑换 / `send` 在同一笔 `execute` 内，失败一并回滚。
- `send` 之后不再跟踪；资金按 UsdtOFT / LayerZero / Mesh 规则处理。
- 非 6 位小数代币可用；2 bps 仍按该币最小单位对 `amountIn` 计。
- 本合约无签名与 nonce，重放防护由调用方自行保证。
- `claimFee` 的 `amount==1` 表示全部，无法精确提取 1 个最小单位。
- 3pool 兑出可能比询价少 1 wei；本地源码会把 OFT `minAmountLD` 夹到 `amountLD`。若链上字节码较旧，fork 测试里 3pool SwapBridge 仍可能 OFT `Slippage`。
