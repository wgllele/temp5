# StablecoinBridgeTron

Solidity `>=0.8.11`。整体路径见 [StablecoinBridge](./StablecoinBridge.md)。与 [StablecoinBridgeRouter](./StablecoinBridgeRouter.md)（ETH→波场，可兑可跨）同目录；本合约部署在**波场主网**。

**本合约只跨、不兑：** 拉 TRC20 USDT → 扣协议费留在本合约 → UsdtOFT `send` → 以太坊 USDT。失败整笔回滚；累计手续费与滞留资产由 owner `claimFee` 提出。

**跨链到账后再兑：** 不在本合约内，也不走 `StablecoinBridgeRouter`。用户对以太坊 **Curve 官方 3pool** `approve` + `exchange`（见 §4.5）。波场侧不做 swap。

必须先 `quote`，把返回的 `outAmount`、`nativeFee` 写入 `execute` 的 `destAmount` / `nativeFee`，再 `execute{value: nativeFee}`。`msg.value` 必须 **等于** `nativeFee`（单位 TRX **sun**），合约 **不退** 多余 TRX。

**波场主网：** `TG1tdbbj4crisqw6DZPeApAFnUE72mYh5R`（[tronscan](https://tronscan.org/contract/TG1tdbbj4crisqw6DZPeApAFnUE72mYh5R/code)）。  
**USDT_OFT（波场）：** `0x3a08F76772e200653bB55c2a92998DAcA62e0e97`（`TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt`），来自 ETH `0x1F748c76…dfb0.peers(30420)`。旧址 `TTF3jaLnaMLhZwQ32J89jXuSkFwrtSKG8t`（错误 OFT）已废弃。

---

## 1. 业务架构

```
波场                                              以太坊
调用方 ──approve──► StablecoinBridgeTron
                         │
                    划 2 bps 留存
                         │
                    UsdtOFT.send ═══════════════► recipient 钱包（ETH USDT）
                                                      │
                                                      │ 可选，跨链已结束
                                                      ▼
                                                 Curve 官方 3pool
                                                 approve + exchange
                                                      │
                                                      ▼
                                                 USDC / DAI 等（仍在 ETH）
```

| 角色 | 职责 |
|---|---|
| 调用方 `msg.sender` | 事先 `approve` 本合约；先 `quote` 填 `nativeFee`/`destAmount`，再 `execute{value: nativeFee}` |
| owner | 改管理员、写 `feeRecipient`、`claimFee` |
| `feeRecipient` | 仅 `claimFee` 收款地址；交易过程不向外转手续费 |
| `USDT_OFT` | 波场 UsdtOFT（LayerZero V2 / USDT0 Legacy Mesh） |
| Curve 3pool（ETH） | **跨链后**可选兑换；用户直接调官方池，不经过本合约 / Router |

```
StablecoinBridgeTron（本合约）
├── 报价：quote（OFT 到账 + nativeFee）
├── 执行：execute（payable + nonReentrant）
├── 治理：owner / setOwner / setFeeRecipient / claimFee
└── 代币：汇编 transfer / transferFrom / approve / balanceOf；receive/fallback payable

跨链后 swap（非本合约）
└── Curve 3pool：get_dy → approve(3pool) → exchange
```

USDT、ETH_USDT、USDT_OFT 为 **public constant**。可变状态：`_owner`、`_feeRecipient`、重入锁 `_status`。构造仅 `initOwner`。

---

## 2. 业务能力

| 阶段 | 谁执行 | 说明 |
|---|---|---|
| 跨链 | 本合约 | 波场 USDT → 以太坊 USDT；无 Curve、无 `swapType` / `methodType` |
| 跨链后 swap | 用户直接调 Curve 官方池 | USDT→USDC/DAI 等；**不要** `approve` 本合约或 Router |

协议费固定 **2 bps**：`fee = amountIn * PROTOCOL_FEE_BPS / 10000`（`PROTOCOL_FEE_BPS=2`）。在 `send` **之前**从 USDT 全额划出，留在本合约，不转给 `feeRecipient`。池侧另有 Curve 费（约 1.5 bps），与协议费分开。

| 场景 | 说明 |
|---|---|
| 只跨 | 先 `quote`，再带 TRX 调 `execute`；终点为以太坊 `recipient` 的 USDT |
| 跨后再兑 | 等 Mesh 到账后，对 3pool `approve` + `exchange`（§4.5） |

与 ETH Router 对照：

| | StablecoinBridgeRouter | StablecoinBridgeTron |
|---|---|---|
| 部署链 | 以太坊 | 波场 |
| 方向 | ETH → 波场（合约内可兑再跨） | 波场 → ETH（只跨） |
| swap | `methodType=0/1` 在合约内调 Curve | **本合约无 swap**；到账后再兑走官方 3pool |
| `msg.value` | ETH wei | TRX sun |
| `recipient` | 波场 20 字节体（合约加 `0x41`） | 以太坊 20 字节（左垫 12 字节 0） |
| `destChainId` | `30420` / `728126428` | `30101` / `1` |

---

## 3. `quote` / `execute` 参数

| 字段 | 含义 |
|---|---|
| `recipient` | 以太坊收款地址，**必须非 0** |
| `amountIn` | 拉入波场 USDT 数量（含协议费） |
| `destChainId` | 仅以太坊：`30101`（LZ EID）或 `1` |
| `destToken` | `0` 或 ETH USDT `0xdAC17F…`；其它 → `BridgeTokenMustBeUsdt` |
| `destAmount` | 写入询价 `minAmountLD`；成交时须 ≥ `quoteOFT.amountReceivedLD * 9900/10000` |
| `nativeFee` | 询价 `quoteSend(..., false)` 的 sun；`msg.value` 必须相等 |

返回 / 成交：

| 方法 | 含义 |
|---|---|
| `quote` → `outAmount` | 目的链预计到账，写入 `execute.destAmount` |
| `quote` → `nativeFee` | 作 `execute` 的 `msg.value` |
| `execute` 返回值 | OFT `send` 返回的目的链预计到账 |

---

## 4. 业务流程

### 4.1 调用前

1. 确定以太坊 `recipient`、`amountIn`。
2. `destChainId = 30101` 或 `1`；`destToken = 0` 或 ETH USDT。
3. `triggerConstantContract` / 只读调用 `quote`。
4. `destAmount = outAmount`，`nativeFee` 原样保存。
5. `approve(本合约, amountIn)`（不是 OFT）。波场 USDT 若已有非 0 授权，先 `approve(0)`。
6. `execute{value: nativeFee}(...)`。

### 4.2 `execute` 主流程

```
approve(Router, amountIn)
        │
quote → 写入 nativeFee、destAmount
        │
execute{value: nativeFee}(...)
        │
校验 msg.value == nativeFee
拉 USDT → 划 2 bps → UsdtOFT.send
不退多余 TRX
```

`execute` / `claimFee` 均 `nonReentrant`。成功发 `FeeCharged`（若 fee≠0）、`Bridge`（`amount` 为目的链预计到账）。

### 4.3 跨链（对齐 UsdtOFT）

| 步骤 | 本合约 |
|---|---|
| 1. ETH 地址 → `bytes32` | `oftTo`：`12 字节 0 + 20 字节` |
| 2. `quoteOFT` + `quoteSend(..., false)` | `quote` |
| 3. USDT `approve(OFT)` | 调用方 `approve(本合约)`；合约再授权 OFT |
| 4. `send{value: nativeFee}` | `execute{value: nativeFee}`；`refundAddress = msg.sender` |

`extraOptions` / `composeMsg` / `oftCmd` 均为空。其它 `destChainId` → `UnknownDestChain`。

成交时（`_oftSend`）：

1. 若 `destAmount >` 实际 USDT 净额，把 `minAmountLD` 夹到 `amountLD`。
2. 再 `quoteOFT`；要求 `destAmount ≥ amountReceivedLD * OFT_MIN_BPS / 10000`（99%）。
3. `destAmount = 0` → `ZeroAmount`。

多付、少付 TRX 都 `NativeFeeMismatch`。OFT 若退网络费，退到 `msg.sender`。滞留 TRX 只能 `claimFee(address(0), …)`。

### 4.4 治理

1. `setFeeRecipient`：写 `claimFee` 收款地址。
2. `claimFee(token, amount)`：ERC20 或 `token=0`（TRX）转到 `feeRecipient`。`amount==1` 表示全部；`0` → `ZeroAmount`；超过余额 → `FeeExceedsAmount`。
3. `setOwner`：移交管理员。

`receive` / `fallback` 均为 `payable`。

### 4.5 跨链到账后再 swap（不走本合约 / Router）

跨链已结束：以太坊 `recipient` 已持有 USDT。若还要换成 USDC、DAI 等，用户在**以太坊**直接调 **Curve 官方 3pool**，**不要** `approve` `StablecoinBridgeTron`，也 **不要** `approve` `StablecoinBridgeRouter`（Router 是 ETH→波场用的）。

```
get_dy（只读）
    │
tokenIn.approve(3pool, dx)
    │
3pool.exchange(i, j, dx, min_dy)
```

| 顺序 | 动作 | 签名 |
|---|---|---|
| 0 | 等 LayerZero / Mesh 到账；确认钱包 ETH USDT 余额 | 否 |
| 1 | `eth_call get_dy(i, j, dx)`，`min_dy` 按报价留滑点 | 否 |
| 2 | `tokenIn.approve(3pool, dx)`；USDT 若已有非 0 授权先 `approve(0)` | 是 |
| 3 | `3pool.exchange(i, j, dx, min_dy)` selector `0x3df02124` | 是 |

| 项 | 值 |
|---|---|
| 池 | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` |
| 索引 | `0=DAI`，`1=USDC`，`2=USDT` |
| USDT → USDC | `exchange(2, 1, dx, min_dy)`，先 `USDT.approve(3pool, dx)` |
| USDC → USDT | `exchange(1, 2, dx, min_dy)`，先 `USDC.approve(3pool, dx)` |
| 池费 | 约 1.5 bps，与本合约 2 bps 协议费分开 |
| `min_dy` | 用对应方向 `get_dy` 再扣滑点，不要写死 |

资金终点仍在以太坊。产品上这是跨链之后的**另两笔**以太坊签名（approve + exchange），与波场侧 `approve` + `execute` 分开。

---

## 5. 常量

| 名 | 值 |
|---|---|
| `PROTOCOL_FEE_BPS` | `2` |
| `OFT_MIN_BPS` | `9900` |
| `LZ_EID_ETH` | `30101` |
| `ETH_CHAIN_ID` | `1` |
| `USDT` | `0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C`（`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`） |
| `ETH_USDT` | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| `USDT_OFT` | `0x3a08F76772e200653bB55c2a92998DAcA62e0e97`（`TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt`） |
| Curve 3pool（跨链后 swap） | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` |
| ETH USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |

---

## 6. 外部调用

不 import OFT 接口，按 selector 内联汇编：

| 方法 | Selector |
|---|---|
| `quoteOFT` | `0x0d35b415`（`amountReceivedLD` 在返回 `0x80`） |
| `quoteSend` | `0x3b6f743b`（只取 `nativeFee`） |
| `send` | `0xc7c7f5b3`（收到量在返回 `0xa0`） |

ERC20：`approve` 先置 0；只检查 call 成功。

---

## 7. 状态、权限与事件

| 状态 | 可变性 | 谁改 |
|---|---|---|
| USDT / ETH_USDT / USDT_OFT | `constant` | 编译期 |
| `_owner` | storage | `setOwner` |
| `_feeRecipient` | storage | `setFeeRecipient` |
| `_status` | storage | 重入锁 |

- `execute`：任意已对本合约授权 USDT 的地址。
- `setOwner` / `setFeeRecipient` / `claimFee`：`onlyOwner`。

| 事件 | 何时 |
|---|---|
| `FeeCharged` | 本笔已划出协议费 |
| `Bridge` | UsdtOFT 已 `send` |
| `FeeRecipientUpdated` | 更新收款地址 |
| `OwnerChanged` | 更换 owner |

自定义错误：`OwnableUnauthorizedAccount`、`OwnableInvalidOwner`、`ZeroAmount`、`Slippage`、`ZeroAddress`、`FeeExceedsAmount`、`ClaimFailed`、`ReentrancyGuardReentrantCall`、`UnknownDestChain`、`BridgeTokenMustBeUsdt`、`NativeFeeMismatch`。

---

## 8. 边界与对接注意

- 协议费与 `send` 同笔；失败一并回滚。
- `send` 之后不跟踪；到账按 UsdtOFT / LayerZero / Mesh，有延迟；到账后再兑须等余额可见。
- `recipient` 填**以太坊**地址，不要填波场 `T…`。
- `nativeFee` / `msg.value` 是 **sun**（1 TRX = 1e6 sun），不是 wei。
- 询价到上链之间 Mesh/费会变；过期重新 `quote`。
- `claimFee` 的 `amount==1` 表示全部，无法精确提取 1 个最小单位。
- 本合约无 deadline / nonce，重放由调用方自行保证。
- 不要 `approve` OFT；不要多付 TRX 指望退款。
- 跨链后 swap：**只** `approve` Curve 官方 3pool，不要 `approve` 本合约或 Router；`min_dy` 用当次 `get_dy`。

### 联调检查单

- [ ] 部署链为波场；`USDT` / `USDT_OFT` 已与链上核对
- [ ] `recipient` 为有效 ETH 地址
- [ ] USDT 先 `approve(0)` 再授权本合约（若原授权非 0）
- [ ] `destAmount` / `nativeFee` / `call_value` 与当次 `quote` 一致
- [ ] 展示 2 bps 协议费 + `outAmount`
- [ ] 若跨后再兑：等 Mesh 到账 → `get_dy` → `approve(3pool)` → `exchange`；未误调 Router
- [ ] 展示 Curve 池费 / 滑点与协议费分开
