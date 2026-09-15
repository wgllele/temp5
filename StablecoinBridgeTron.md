# StablecoinBridgeTron

Solidity `>=0.8.11`。整体路径见 [StablecoinBridge](./StablecoinBridge.md)。与 [StablecoinBridgeRouter](./StablecoinBridgeRouter.md)（ETH→波场，可兑可跨）同目录。

**本合约只跨、不兑：** 拉 TRC20 USDT → 扣协议费留在本合约 → UsdtOFT `send` → 以太坊 USDT。失败整笔回滚；累计手续费与滞留资产由 owner `claimFee` 提出。

**跨链到账后再兑：** 不在本合约内。可选：以太坊 **Curve 官方 3pool** `approve` + `exchange`（§4.5，不收我们的 2 bps）；或到账后走 Router `methodType=0` 收费兑换（见总览）。波场侧不做 swap。

必须先 `quote`，`nativeFee` 原样写入 `execute`；`minAmountLD = quote.outAmount` 链下按 `oftToleranceBps` 打折，再 `execute{value: nativeFee}`。`msg.value` 必须 **等于** `nativeFee`（单位 TRX **sun**），合约 **不退** 多余 TRX。`quote` 已按毛额扣 **2 bps** 再询 OFT。

成交校验：`quoteOFT.amountReceivedLD ≥ minAmountLD`，否则 `OftSlippage`（**不是** Curve 的 `Slippage`；**不算** UI「总滑点」）。

### 部署状态（重要）

| | 地址 | 说明 |
|---|---|---|
| **源码（本仓库最新）** | 未上链 / 待发 | `execute(..., minAmountLD, nativeFee)` + `OftSlippage`；**无** `OFT_MIN_BPS` |
| **链上旧版** | `TG1tdbbj4crisqw6DZPeApAFnUE72mYh5R`（hex `0x4252aB…C43B`） | 仍为旧 ABI：`destAmount` + 错误逻辑 `destAmount ≥ quoted×99%`（`OFT_MIN_BPS`），**勿再对接**；须用本仓库源码**重新部署**后更新下表 |
| **USDT_OFT** | `0x3a08F76772e200653bB55c2a92998DAcA62e0e97`（`TFG4wBa…`） | = ETH `0x1F748c76…dfb0.peers(30420)`；常量正确 |
| 废弃 | `TTF3jaLnaMLhZwQ32J89jXuSkFwrtSKG8t` | 曾误写 ETH OFT，`quote` revert |

旧版致命逻辑（勿再使用）在 `_oftSend`：`if (destAmount < quoted * 9900/10000) revert Slippage`——方向反了。新版为 `if (quoted < minAmountLD) revert OftSlippage`。

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
| 调用方 `msg.sender` | 事先 `approve` 本合约；先 `quote` 填 `nativeFee`/`minAmountLD`，再 `execute{value: nativeFee}` |
| owner | 改管理员、写 `feeRecipient`、`claimFee` |
| `feeRecipient` | 仅 `claimFee` 收款地址；交易过程不向外转手续费 |
| `USDT_OFT` | 波场 UsdtOFT（LayerZero V2 / USDT0 Legacy Mesh） |
| Curve 3pool（ETH） | **跨链后**可选兑换；用户直接调官方池，不经过本合约 |

```
StablecoinBridgeTron（本合约）
├── 报价：quote（扣费后 OFT 到账 + nativeFee）
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
| 跨链后 swap | 用户直接调 Curve 官方池 | USDT→USDC/DAI 等；**不要** `approve` 本合约 |

协议费固定 **2 bps**：`fee = amountIn * PROTOCOL_FEE_BPS / 10000`。在 `send` **之前**从 USDT 全额划出，留在本合约。池侧另有 Curve 费（约 1.5 bps），与协议费分开。

与 ETH Router 对照：

| | StablecoinBridgeRouter | StablecoinBridgeTron |
|---|---|---|
| 部署链 | 以太坊（源码最新；链上 `0x4A760E…` 若未重发则为旧 ABI） | 波场（**须重发**；`TG1tdbbj…` 为旧版） |
| 方向 | ETH → 波场（合约内可兑再跨） | 波场 → ETH（只跨） |
| swap | `methodType=0/1` 在合约内调 Curve | **本合约无 swap**；到账后再兑走官方 3pool |
| `msg.value` | ETH wei | TRX sun |
| `recipient` | 波场 20 字节体（合约加 `0x41`） | 以太坊 20 字节（左垫 12 字节 0） |
| `destChainId` | `30420` / `728126428` | `30101` / `1` |
| OFT | ETH `0x1F748c…`（常量名 `ACROSS_PROTOCOL`） | 波场 `0x3a08F767…` |
| 跨链下限参数 | `minAmountLD` → `OftSlippage` | 同左 |
| Curve 下限 | `minAmountOut` → `Slippage` | 无 |

### `execute` ABI（最新源码）

```text
execute(address recipient, uint256 amountIn, uint256 destChainId, address destToken, uint256 minAmountLD, uint256 nativeFee) payable returns (uint256)
```

旧版参数名 `destAmount` 且带 `OFT_MIN_BPS` 校验，**选择器/语义均不同**，前端须换新地址。

---

## 3. `quote` / `execute` 参数

| 字段 | 含义 |
|---|---|
| `recipient` | 以太坊收款地址，**必须非 0**（不是 `T…`） |
| `amountIn` | 拉入波场 USDT 数量（含手续费） |
| `destChainId` | 仅以太坊：`30101`（LZ EID）或 `1` |
| `destToken` | **不参与发币**。`0` 跳过校验；非 0 时必须是 ETH USDT，否则 `BridgeTokenMustBeUsdt` |
| `minAmountLD` | 跨链到账下限（对齐 OFT `SendParam.minAmountLD`）；按 `quote.outAmount` 链下打折；不足 → `OftSlippage` |
| `nativeFee` | 询价 `quoteSend(..., false)` 的 sun；`msg.value` 必须相等 |

返回 / 成交：

| 方法 | 含义 |
|---|---|
| `quote` → `outAmount` | 扣 2 bps 后目的链预计到账 → 链下打折得 `execute.minAmountLD` |
| `quote` → `nativeFee` | → `execute` 的 `msg.value` |
| `execute` 返回值 | OFT `send` 返回的目的链预计到账 |

### 3.1 `quote` 参数例子（100 USDT）

| 参数 | 例子 |
|---|---|
| `recipient` | `0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0`（以太坊地址） |
| `amountIn` | `100000000`（6 位小数） |
| `destChainId` | `30101` |
| `destToken` | `0x0000000000000000000000000000000000000000` |

主网曾测：`outAmount ≈ 99950006`，`nativeFee` 约数 TRX（随 Mesh 费变，以当次 `quote` 为准）。

---

## 4. 业务流程

### 4.1 调用前

1. 确定以太坊 `recipient`、`amountIn`。
2. `destChainId = 30101` 或 `1`；`destToken = 0` 或 ETH USDT。
3. `triggerConstantContract` / 只读调用 `quote`（若 `constant_result` 为空，多为 OFT 地址错误或 REVERT）。
4. `minAmountLD = outAmount * (10000 - oftToleranceBps) / 10000`（报价漂移保底，建议 15～20；**不算 UI 总滑点**），`nativeFee` 原样保存。
5. `approve(本合约, amountIn)`（不是 OFT）。波场 USDT 若已有非 0 授权，先 `approve(0)`。
6. `execute{value: nativeFee}(...)`。

### 4.2 `execute` 主流程

```
approve(BridgeTron, amountIn)
        │
quote → 写入 nativeFee；minAmountLD = outAmount 链下打折
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

1. `minAmountLD == 0` → `ZeroAmount`。
2. 发给 OFT 的 `SendParam.minAmountLD` = `min(minAmountLD, usdtAmt)`（OFT 要求不超过 `amountLD`）。
3. 再 `quoteOFT`；要求 **`amountReceivedLD ≥ minAmountLD`（用调用方原值，不因夹紧而降低保底）**。低于则 `OftSlippage(quoted, minAmountLD)`。
4. `send{value: nativeFee}`；`refundAddress = msg.sender`。

多付、少付 TRX 都 `NativeFeeMismatch`。OFT 若退网络费，退到 `msg.sender`。滞留 TRX 只能 `claimFee(address(0), …)`。部署后务必先 `setFeeRecipient`，否则无法 `claimFee`。

### 4.4 治理

1. `setFeeRecipient`：写 `claimFee` 收款地址。
2. `claimFee(token, amount)`：ERC20 或 `token=0`（TRX）转到 `feeRecipient`。`amount==1` 表示全部；`0` → `ZeroAmount`；超过余额 → `FeeExceedsAmount`。
3. `setOwner`：移交管理员。

`receive` / `fallback` 均为 `payable`。

### 4.5 跨链到账后再 swap（不走本合约）

跨链已结束：以太坊 `recipient` 已持有 USDT。若还要换成 USDC、DAI 等，用户在**以太坊**直接调 **Curve 官方 3pool**，**不要** `approve` 本合约。若要走我们收费兑换，用 Router `methodType=0`（见 [StablecoinBridge](./StablecoinBridge.md) §4）。

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
| USDT → USDC | `exchange(2, 1, dx, min_dy)` |
| 池费 | 约 1.5 bps，与本合约 2 bps 协议费分开 |
| `min_dy` | 用对应方向 `get_dy` 再扣滑点，不要写死 |

---

## 5. 常量

| 名 | 值 |
|---|---|
| `PROTOCOL_FEE_BPS` | `2` |
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

自定义错误：`OwnableUnauthorizedAccount`、`OwnableInvalidOwner`、`ZeroAmount`、`OftSlippage`、`ZeroAddress`、`FeeExceedsAmount`、`ClaimFailed`、`ReentrancyGuardReentrantCall`、`UnknownDestChain`、`BridgeTokenMustBeUsdt`、`NativeFeeMismatch`。

---

## 8. 边界与对接注意

- 协议费与 `send` 同笔；失败一并回滚。
- `send` 之后不跟踪；到账按 UsdtOFT / LayerZero / Mesh，有延迟。
- `recipient` 填**以太坊**地址，不要填波场 `T…`。
- `nativeFee` / `msg.value` 是 **sun**（1 TRX = 1e6 sun），不是 wei。
- 询价到上链之间 Mesh/费会变；过期重新 `quote`。
- `claimFee` 的 `amount==1` 表示全部，无法精确提取 1 个最小单位。
- 本合约无 deadline / nonce，重放由调用方自行保证。
- 不要 `approve` OFT；不要多付 TRX 指望退款。
- `USDT_OFT` 必须用 EIP-55 校验和地址编译；波场 peer **不是** ETH 的 `0x1F748c…`。

### 联调检查单

- [ ] 已用**本仓库最新源码**重新部署；勿用 `TG1tdbbj…` 旧字节码
- [ ] 部署后 `setFeeRecipient`；链上 `USDT_OFT() == 0x3a08F767…`
- [ ] `quote` 有非空 `constant_result`（`outAmount` + `nativeFee`）
- [ ] `recipient` 为有效 ETH 地址
- [ ] USDT 先 `approve(0)` 再授权本合约（若原授权非 0）
- [ ] `minAmountLD = outAmount * (10000 - oftToleranceBps) / 10000`（建议 15～20）；`nativeFee` / `call_value` 与当次 `quote` 一致
- [ ] 展示 2 bps 协议费 + `outAmount`；**不要**把 `oftToleranceBps` 算进 UI 总滑点
- [ ] 故意抬高 `minAmountLD` 应得到 `OftSlippage`（验证新逻辑）
- [ ] 若跨后再兑：等 Mesh 到账 → `get_dy` → `approve(3pool)` → `exchange`
