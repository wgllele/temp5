# UsdtOFT（USDT0 Legacy Mesh）

以太坊主网源码镜像目录：[`../eth_0x1f748c76de468e9d11bd340fa9d5cbadf315dfb0_code`](../eth_0x1f748c76de468e9d11bd340fa9d5cbadf315dfb0_code/)。  
业务总览见 [StablecoinBridge.md](./StablecoinBridge.md)；入口合约见 [StablecoinBridgeRouter.md](./StablecoinBridgeRouter.md) / [StablecoinBridgeTron.md](./StablecoinBridgeTron.md)。

本文件说明 **Mesh 通道本身**：锁仓 / credits / `quoteOFT`·`quoteSend`·`send`，以及和我们 Router / BridgeTron 的参数对应。用户**不要**直接调 UsdtOFT；只 `approve` 我们的入口合约。

---

## 1. 合约与地址

| 角色 | 链 | 地址 |
|---|---|---|
| UsdtOFT（本篇） | 以太坊 | `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0` |
| UsdtOFT peer | 波场 | `0x3a08F76772e200653bB55c2a92998DAcA62e0e97`（`TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt`） |
| 底层 USDT | 以太坊 | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| 底层 USDT | 波场 | `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`（`0xa614f803…`） |
| 我们的 Router | 以太坊 | [`0xcda2c4eaC941F9d4b6003bCeEbF3d2C5805AD121`](https://etherscan.io/address/0xcda2c4eac941f9d4b6003bceebf3d2c5805ad121#code)（常量名 `ACROSS_PROTOCOL` 指向本 UsdtOFT） |
| 我们的 BridgeTron | 波场 | [`TMgkQyjZb11XJBVH2aqnKrxhot4erYduV7`](https://tronscan.org/contract/TMgkQyjZb11XJBVH2aqnKrxhot4erYduV7/code) |

双向 peer：

```text
ETH UsdtOFT.peers(30420) → 0x3a08F767…
波场 UsdtOFT.peers(30101) → 0x1F748c76…
```

---

## 2. 业务模型（不是 mint/burn）

标准 LayerZero OFT 常在源链 burn、目的链 mint。**UsdtOFT 是锁仓 + 额度（credits）模型**：

```
源链用户/Router
      │ approve + send
      ▼
┌─────────────────────┐         LayerZero V2          ┌─────────────────────┐
│ 源链 UsdtOFT         │ ──── SEND_OFT 消息 ─────────► │ 目的链 UsdtOFT       │
│ 1. 锁入真实 USDT     │                               │ 1. _lzReceive        │
│ 2. 扣 feeBps (Mesh)  │                               │ 2. 转出锁定的 USDT   │
│ 3. credits[dst] -=   │                               │    给 SendParam.to   │
│ 4. credits[LOCAL] += │                               └─────────────────────┘
└─────────────────────┘
```

| 概念 | 含义 |
|---|---|
| `innerToken` | 本链真实 USDT |
| `credits[eid]` | 该目的链**还能再接收**多少 USDT（流动性额度） |
| `feeBps` | Mesh 协议费率；`amountReceived = amountSent × (1 - feeBps/10000)` |
| `feeBalance` | 已累计、可由 LP/owner 提取的 Mesh 费 |
| `tvl()` | `balanceOf(this) - feeBalance` |

`quoteOFT` 的 `maxAmountLD = credits[dstEid]`：额度不够则无法跨到该链。

---

## 3. 与我们入口合约的分工

| 费用 / 动作 | 谁收 / 谁做 |
|---|---|
| 协议费 **2 bps** | `StablecoinBridgeRouter` / `StablecoinBridgeTron`（从 tokenIn 先扣，留在入口合约） |
| Mesh 费 `feeBps` | **UsdtOFT**（`_debitView`，体现在 `amountReceivedLD`） |
| LayerZero 网络费 | 用户垫：ETH 上为 wei，波场上为 TRX sun → `quoteSend.nativeFee` |
| Curve 兑换 | 仅 Router `methodType` 0/1；UsdtOFT 不碰 |
| `approve` 对象 | 用户只 approve **入口合约**；入口再 approve UsdtOFT |

```
用户
 │
 ├─ ETH→波场：approve(Router) → Router.execute
 │                              → 扣 2 bps → (可选 Curve) → UsdtOFT.send
 │
 └─ 波场→ETH：approve(BridgeTron) → BridgeTron.execute
                                    → 扣 2 bps → 波场 UsdtOFT.send
```

---

## 4. 对 Router / BridgeTron 暴露的三个接口

实现见镜像 `contracts/UsdtOFT.sol`；标准定义见 `IOFT.sol`。

### 4.1 `quoteOFT(SendParam) → (OFTLimit, OFTFeeDetail[], OFTReceipt)`

Selector：`0x0d35b415`。只读。

| 返回字段 | UsdtOFT 行为 | 入口合约用法 |
|---|---|---|
| `limit.maxAmountLD` | `credits[dstEid]` | 上限参考 |
| `oftFeeDetails` | 空数组 | 忽略 |
| `receipt.amountSentLD` | = `amountLD` | — |
| `receipt.amountReceivedLD` | 扣 `feeBps` 后 | Router/Tron `quote.outAmount` / 校验滑点 |

### 4.2 `quoteSend(SendParam, payInLzToken=false) → MessagingFee`

Selector：`0x3b6f743b`。只读。

| 返回 | 用法 |
|---|---|
| `nativeFee` | 入口 `execute` 的 `msg.value`（ETH wei / TRX sun） |
| `lzTokenFee` | 路径为 0 |

会先走与 `send` 相同的 `_debitView` + `_assertCredits`，再 `_quote` Endpoint。

### 4.3 `send(SendParam, MessagingFee, refundAddress) payable`

Selector：`0xc7c7f5b3`。

```
_debitView(amountLD, minAmountLD)     // Mesh 费 + 滑点
safeTransferFrom(msg.sender, this)  // 锁 USDT
credits[dst] -= amountReceived
credits[LOCAL] += amountReceived
feeBalance += fee
_lzSend(... SEND_OFT ...)
return OFTReceipt(amountSent, amountReceived)
```

入口合约汇编：`refundAddress = msg.sender`；`extraOptions/composeMsg/oftCmd` 为空。

---

## 5. `SendParam` 字段

| 字段 | 含义 | 我们入口的填法 |
|---|---|---|
| `dstEid` | 目的 LZ EID | ETH→波场：`30420`；波场→ETH：`30101` |
| `to` | 目的收款 `bytes32` | 见下节 |
| `amountLD` | 本链锁入毛额（6 位） | 入口扣 2 bps 后的净 USDT |
| `minAmountLD` | 扣 Mesh 后到账下限 | 入口的 **`minAmountLD`**（调用方传入；成交前 `quoteOFT ≥ minAmountLD`，否则入口 `OftSlippage`） |
| `extraOptions` | LZ options | `0x` |
| `composeMsg` | compose | `0x`（非空会走 `SEND_OFT_AND_CALL`） |
| `oftCmd` | 未使用 | `0x` |

### 5.1 `to` 打包（最易错）

| 方向 | `to` 布局 |
|---|---|
| 以太坊 → 波场 | `11 字节 0` + `0x41` + 波场地址 **20 字节体**（去掉 Base58 的 `41`） |
| 波场 → 以太坊 | `12 字节 0` + 以太坊 **20 字节**地址 |

Router：`oftTo` = `(0x41 << 160) | uint160(recipient)`。  
BridgeTron：`oftTo` = `bytes32(uint256(uint160(recipient)))`。

---

## 6. 消息类型 msgType

payload 前 **2 字节**：

| 值 | 常量 | 谁用 | 目的链行为 |
|---|---|---|---|
| 1 | `WITHDRAW_REMOTE` | LP `withdrawRemote` | 解锁打给 `to` |
| 2 | `SEND_OFT` | **用户跨链 / 我们的入口** | `_receiveOFT` 转 USDT |
| 3 | `SEND_CREDITS` | Planner `sendCredits` | 增加本链各 eid credits |
| 4 | `SEND_OFT_AND_CALL` | 带 composeMsg 的 send | 转 USDT + `sendCompose` |

用户路径只关心 **2**。

---

## 7. 扣费与滑点（Mesh 层）

```solidity
// UsdtOFT._debitView
amountSent = amountLD;
feeAmount = amountSent * feeBps / 10000;
amountReceived = amountSent - feeAmount;
require(amountReceived >= minAmountLD); // 否则 SlippageExceeded
```

与入口合约滑点 / 保底的关系：

| 层 | 规则 |
|---|---|
| 入口 2 bps | 在调 OFT **之前**从用户 `amountIn` 扣 |
| UsdtOFT `feeBps` | OFT 内再扣；`quoteOFT.amountReceivedLD` 已含 |
| 入口 `minAmountLD` | 调用方按 `quote.outAmount` × `(10000 - oftToleranceBps)/10000` 传入；合约要求成交时 `quoteOFT ≥ minAmountLD` → 否则 **`OftSlippage`** |
| Curve `minAmountOut` | 仅 Router；不足 → **`Slippage`**；与 OFT 分开，**不算进同一「总滑点」展示时不要把 oftTolerance 加进去** |

展示「跨链预计到账」用入口 `quote.outAmount`（已含 2 bps + Mesh），不要自己 1:1 估算。

> **旧版勿用：** `OFT_MIN_BPS` / `destAmount ≥ quoted×99%` 方向错误，已从最新入口源码移除。

---

## 8. 角色与运维接口（非用户路径）

| 角色 | 权限摘要 |
|---|---|
| `owner` | 设 admin、`feeBps`、移交所有权 |
| `lpAdmin` / owner | `depositLocal` / `withdrawLocal` / `withdrawRemote` / `withdrawFees` |
| `planner` | `sendCredits`（链间调额度） |
| `burnAndNilifyAdmin` | Endpoint `nilify` / `burn` |

用户 / 商户后台**不需要**调这些。额度不足时 `send` / `quoteSend` 会 `InsufficientCredits`，表现为入口询价或成交失败。

---

## 9. 源码索引

| 路径 | 内容 |
|---|---|
| `…/contracts/UsdtOFT.sol` | 实现（已加中文注释） |
| `…/contracts/IUsdtOFT.sol` | Mesh 扩展接口 |
| `…/@layerzerolabs/.../IOFT.sol` | 标准 `SendParam` / `quoteOFT` / `quoteSend` / `send` |
| `…/abi.json` | 链上 ABI |

标准库实现也可对照：[OFTCore.send](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/oapp/contracts/oft/OFTCore.sol)（通用 OFT；本 UsdtOFT 为自定义 version=0）。

---

## 10. 对接注意

- 不要让用户 `approve` UsdtOFT；只 approve Router / BridgeTron。
- `nativeFee` / `msg.value` 必须用当次 `quoteSend`；入口合约要求严格相等且不退多余。
- `send` 之后到账有 LZ/Mesh 延迟；入口不跟踪目的链确认。
- 波场 USDT 无 bool 返回：UsdtOFT 在 `LOCAL_EID == TRON` 时用普通 `transfer`。
- 入口常量 `USDT_OFT` 必须是**本链 peer**，不能把 ETH 地址写到波场（会导致 `quote` revert）。

### 联调检查单

- [ ] ETH `peers(30420)` / 波场 `peers(30101)` 互指正确
- [ ] `credits(目的 EID)` 足以覆盖本次 `amountReceivedLD`
- [ ] 入口 `quote` 返回非空 `outAmount` + `nativeFee`
- [ ] 入口已是最新：`minAmountLD`（非旧 `destAmount`/`OFT_MIN_BPS`）；`msg.value` = 当次 `nativeFee`
- [ ] 展示分清：入口 2 bps、Mesh `feeBps`、LZ 网络费；UI 滑点只含 Curve
