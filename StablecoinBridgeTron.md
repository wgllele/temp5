# StablecoinBridgeTron

Solidity `>=0.8.11`。整体路径见 [StablecoinBridge](./StablecoinBridge.md)。与 [StablecoinBridgeRouter](./StablecoinBridgeRouter.md)（ETH→波场，可兑可跨）同目录；本合约部署在**波场主网**，仅 **USDT 跨到以太坊**，无 swap。

单笔：拉 TRC20 USDT → 扣协议费留在本合约 → UsdtOFT `send`。失败整笔回滚；累计手续费与滞留资产由 owner `claimFee` 提出。

必须先 `quote`，把返回的 `outAmount`、`nativeFee` 写入 `execute` 的 `destAmount` / `nativeFee`，再 `execute{value: nativeFee}`。`msg.value` 必须 **等于** `nativeFee`（单位 TRX **sun**），合约 **不退** 多余 TRX。

尚未部署主网地址时以源码常量为准。`USDT_OFT` 部署前用 ETH UsdtOFT `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0.peers(30420)` 核对 20 字节。

---

## 1. 业务架构

```
                    ┌─────────────┐
                    │    owner    │  setOwner / setFeeRecipient / claimFee
                    └──────┬──────┘
                           │
调用方 ──approve──► ┌──────▼──────────────────────────┐
                    │      StablecoinBridgeTron       │
                    │     拉 USDT → 划费 → OFT.send   │
                    └───┬──────────────────┬──────────┘
                        │                  │
                        ▼                  ▼
                   手续费留存           UsdtOFT.send
                   （claimFee）         （→ 以太坊）
                                           │
                                           ▼
                                      recipient（ETH 地址）
```

| 角色 | 职责 |
|---|---|
| 调用方 `msg.sender` | 事先 `approve` 本合约；先 `quote` 填 `nativeFee`/`destAmount`，再 `execute{value: nativeFee}` |
| owner | 改管理员、写 `feeRecipient`、`claimFee` |
| `feeRecipient` | 仅 `claimFee` 收款地址；交易过程不向外转手续费 |
| `USDT_OFT` | 波场 UsdtOFT（LayerZero V2 / USDT0 Legacy Mesh） |

```
StablecoinBridgeTron
├── 报价：quote（OFT 到账 + nativeFee）
├── 执行：execute（payable + nonReentrant）
├── 治理：owner / setOwner / setFeeRecipient / claimFee
└── 代币：汇编 transfer / transferFrom / approve / balanceOf；receive/fallback payable
```

USDT、ETH_USDT、USDT_OFT 为 **public constant**。可变状态：`_owner`、`_feeRecipient`、重入锁 `_status`。构造仅 `initOwner`。

---

## 2. 业务能力

仅一条路径：**波场 USDT → 以太坊 USDT**。无 Curve、无 `swapType` / `methodType`。

协议费固定 **2 bps**：`fee = amountIn * PROTOCOL_FEE_BPS / 10000`（`PROTOCOL_FEE_BPS=2`）。在 `send` **之前**从 USDT 全额划出，留在本合约，不转给 `feeRecipient`。

| 场景 | 说明 |
|---|---|
| 跨链 | 先 `quote`，再带 TRX 调 `execute`；到账为以太坊侧预计收到量（含 Mesh 扣费） |

与 ETH Router 对照：

| | StablecoinBridgeRouter | StablecoinBridgeTron |
|---|---|---|
| 部署链 | 以太坊 | 波场 |
| 方向 | ETH → 波场（可兑） | 波场 → ETH（只跨） |
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
| `USDT_OFT` | 波场 UsdtOFT；源码暂与 ETH OFT 同 20 字节，上线前核对 |

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
- `send` 之后不跟踪；到账按 UsdtOFT / LayerZero / Mesh。
- `recipient` 填**以太坊**地址，不要填波场 `T…`。
- `nativeFee` / `msg.value` 是 **sun**（1 TRX = 1e6 sun），不是 wei。
- 询价到上链之间 Mesh/费会变；过期重新 `quote`。
- `claimFee` 的 `amount==1` 表示全部，无法精确提取 1 个最小单位。
- 本合约无 deadline / nonce，重放由调用方自行保证。
- 不要 `approve` OFT；不要多付 TRX 指望退款。

### 联调检查单

- [ ] 部署链为波场；`USDT` / `USDT_OFT` 已与链上核对
- [ ] `recipient` 为有效 ETH 地址
- [ ] USDT 先 `approve(0)` 再授权本合约（若原授权非 0）
- [ ] `destAmount` / `nativeFee` / `call_value` 与当次 `quote` 一致
- [ ] 展示 2 bps 协议费 + `outAmount`
