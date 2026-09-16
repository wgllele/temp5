# 波场 ↔ 以太坊 跨链业务架构

跨链和以太坊只兑都是 **approve 我们的合约 + execute**，两次签名。`quote` 为只读。协议费固定 **2 bps**（从 `tokenIn` 先扣，留在合约，owner `claimFee`）。跨链资产仅为 **USDT**，通道为 UsdtOFT / LayerZero V2 Legacy Mesh。

**谁做 swap：**

- **以太坊只兑、不跨链**：走我们的 `StablecoinBridgeRouter`（`methodType=0`），扣 2 bps，合约内调 Curve。
- **以太坊 → 波场** 需要兑换：同样走 Router（`methodType=1`），用户不直接调 Curve。
- **波场 → 以太坊之后** 再兑换、且不经过我们收费：用户直接对 Curve 官方池 `approve` + `exchange`。
- 波场侧不 swap。

合约文档：[StablecoinBridgeTron](./StablecoinBridgeTron.md)（波场→ETH，只跨）· [StablecoinBridgeRouter](./StablecoinBridgeRouter.md)（ETH 只兑收费、ETH→波场）· [前端对接](./StablecoinBridgeRouter.frontend.md)· [UsdtOFT 通道详解](./UsdtOFT.md)

---

## 1. 总图

一张图：上面走我们的合约（跨链或只兑，都是 ① approve ② execute）；不经过我们收费时，才从钱包再往下走官方 Curve。

```
波场                                              以太坊
┌─────────────────────┐                          ┌─────────────────────┐
│ 用户钱包             │                          │ 用户钱包             │
│ TRC20 USDT          │                          │ USDT / USDC 等      │
└──────────┬──────────┘                          └──────────┬──────────┘
           │ ① approve                                      │ ① approve
           │ ② execute                                      │ ② execute
           ▼                                                ▼
┌─────────────────────┐                          ┌─────────────────────┐
│ 我们的跨链合约       │                          │ 我们的合约 Router    │
│ BridgeTron          │◄════ LayerZero / ═══════►│ 扣 2 bps            │
│ 只跨，不兑，扣 2 bps │     USDT0 Mesh           └────┬──────────┬─────┘
└──────────┬──────────┘                         0 只兑│     1/2 跨链│
           ▼                                        │            │
┌─────────────────────┐                             ▼            ▼
│ UsdtOFT             │                    ┌──────────────┐  波场收款 USDT
└─────────────────────┘                    │ 以太坊        │
           │                               │ tokenOut     │
           │  波场 USDT ──send──► 钱包      │ 不跨链、已收费 │
           │  以太坊 USDT ──send──► 波场    └──────────────┘
           │
           │  不走我们的合约、不收 2 bps（可选）
           ▼
┌─────────────────────┐
│ Curve 官方 3pool     │
│ ① approve 3pool     │
│ ② exchange          │
└──────────┬──────────┘
           ▼
     以太坊 USDC 等（仍留在以太坊）
```

| 路径 | 用户 approve 对象 | 第二笔签名 | swap | 资金终点 |
|---|---|---|---|---|
| 波场 → 以太坊 | `StablecoinBridgeTron` | `execute`（垫 `nativeFee` / sun） | 无 | 以太坊用户钱包 USDT |
| 以太坊只兑不跨 | `StablecoinBridgeRouter` | `execute` `methodType=0`，`msg.value=0` | **走我们的合约**，扣 2 bps，内调 Curve | 以太坊 `tokenOut` |
| 到账后再兑（上图向下） | Curve 3pool 官方池 | `exchange(i,j,dx,min_dy)` | **不走我们的合约**，不收 2 bps | 仍在以太坊 |
| 以太坊 → 波场 · 先兑后跨 | `StablecoinBridgeRouter` | `execute{value: nativeFee}` `methodType=1` | **走我们的合约**，扣 2 bps，内调 Curve | 波场 USDT |
| 以太坊 → 波场 · 直跨 | `StablecoinBridgeRouter` | `execute{value: nativeFee}` `methodType=2` | 无 | 波场 USDT |

产品口径是两次签名。USDT 上若已有非 0 授权，须先 `approve(0)` 再 `approve(amount)`，会多一笔。`quote` / `get_dy` 不占签名。

---

## 2. 波场 → 以太坊

波场侧**没有兑换**。到账以太坊后若还要换成 USDC 等：走我们收费用 §4；不经过我们、直对官方池用 §3。

```
quote（只读）
    │
USDT.approve(BridgeTron, amountIn)
    │
execute{value: nativeFee}
    │
拉币 → 划 2 bps → UsdtOFT.send → 以太坊 USDT
```

| 顺序 | 动作 | 签名 |
|---|---|---|
| 0 | `quote(recipient, amountIn, destChainId, destToken)` → `outAmount`, `nativeFee` | 否 |
| 1 | `USDT.approve(BridgeTron, amountIn)`；非 0 授权先置 0 | 是 |
| 2 | `minAmountLD = outAmount * (10000 - oftToleranceBps) / 10000`（建议 15～20，**不算 UI 总滑点**）；`execute{value: nativeFee}` | 是 |
| — | LayerZero / Mesh 到账（有延迟） | 否 |

- `recipient` 填**以太坊** 20 字节地址，不要填波场 `T…`。
- `destChainId`：`30101`（LZ EID）或 `1`。
- `destToken`：不参与发币；填 `0` 或 ETH USDT 即可（非 0 时必须是 USDT）。
- `nativeFee` / `msg.value` 单位是 TRX **sun**。
- 用户 `approve` 本合约，不是 OFT。
- 成交：`quoteOFT ≥ minAmountLD`，否则 `OftSlippage`。
- **部署：** 主网 [`TMgkQyjZb11XJBVH2aqnKrxhot4erYduV7`](https://tronscan.org/contract/TMgkQyjZb11XJBVH2aqnKrxhot4erYduV7/code)。旧址 `TG1tdbbj…` / `TTF3ja…` 勿用。`quote` 空/`REVERT` 时先核对 `USDT_OFT` 是否为波场 peer `0x3a08F767…`。

---

## 3. 波场到以太坊之后再 swap（不走我们的合约）

即总图里从以太坊用户钱包再往下、直对官方池的那一支。跨链已经结束，**不收我们的 2 bps**。用户对 **Curve 官方 3pool** 授权并成交，**不要** `approve` Router。

若希望由我们扣 2 bps 再兑，不要走本节，走 §4。

```
get_dy（只读）
    │
tokenIn.approve(3pool, dx)
    │
3pool.exchange(i, j, dx, min_dy)
```

| 顺序 | 动作 | 签名 |
|---|---|---|
| 0 | `eth_call get_dy(i, j, dx)`，`min_dy` 按报价留滑点 | 否 |
| 1 | `tokenIn.approve(3pool, dx)` | 是 |
| 2 | `3pool.exchange(i, j, dx, min_dy)` selector `0x3df02124` | 是 |

官方池 `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7`。索引 `0=DAI`、`1=USDC`、`2=USDT`。

- USDT → USDC：`exchange(2, 1, dx, min_dy)`，先 `USDT.approve(3pool, dx)`。
- USDC → USDT：`exchange(1, 2, dx, min_dy)`，先 `USDC.approve(3pool, dx)`。
- 池费 1.5 bps，与跨链 2 bps 协议费分开。`min_dy` 用对应方向 `get_dy` 再扣滑点，不要写死。

---

## 4. 以太坊只兑不跨（走我们的合约，收费）

`methodType = 0`。用户只对 Router 签两笔：`approve` + `execute`。Router 先从 `tokenIn` 扣 **2 bps**，再内调 Curve，把 `tokenOut` 打给 `recipient`（`0` 视为 `msg.sender`）。**不跨链**，`msg.value` 必须为 **0**。

```
quote 比池（只读）
    │
tokenIn.approve(Router, amountIn)
    │
execute  methodType=0  value=0
    │
扣 2 bps → Router 调 Curve → tokenOut 留在以太坊
```

| 顺序 | 动作 | 签名 |
|---|---|---|
| 0 | `quote` 比池（3pool / NG），记下 `outAmount`；`nativeFee` 为 0 | 否 |
| 1 | `tokenIn.approve(Router, amountIn)`（不是 3pool、不是 OFT） | 是 |
| 2 | `execute methodType=0`：`msg.value=0`，`minAmountLD=0`，`nativeFee=0`；扣 2 bps 后兑给 `recipient` | 是 |

- 白名单：DAI / USDC / USDT / PYUSD / crvUSD / RLUSD。
- `minAmountOut` 按 `quote.outAmount` 留滑点。多带 1 wei 也会 `NativeFeeMismatch`。
- 用户不要直接调 Curve；Curve 的 approve / exchange 由 Router 完成。

---

## 5. 以太坊 → 波场（兑和跨都走我们的合约）

用户只对 Router 签两笔。需要 swap 时由 Router 在同一笔 `execute` 里调 Curve，**用户不要先单独调 3pool**。

### 5.1 先交易后跨链（`methodType = 1`）

```
quote 比池（只读）
    │
tokenIn.approve(Router, amountIn)
    │
execute{value: nativeFee}  methodType=1
    │
扣 2 bps → Router 调 Curve 兑成 USDT → UsdtOFT.send → 波场 USDT
```

| 顺序 | 动作 | 签名 |
|---|---|---|
| 0 | `quote` 比池（3pool / NG），记下 `outAmount`、`nativeFee`；`minAmountLD` 由 `outAmount` 链下打折；`minAmountOut` 用 Curve 滑点（与 OFT 分开） | 否 |
| 1 | `tokenIn.approve(Router, amountIn)`（不是 3pool、不是 OFT） | 是 |
| 2 | `execute methodType=1`：扣 2 bps → 合约内 Curve → `UsdtOFT.send` | 是 |

`tokenOut` 必须是 USDT。跨链 `recipient` 为去掉 `41` 的波场 20 字节体（不要填 `T…` 字符串，也不要填带 `41` 的 21 字节）。

### 5.2 直接跨链（`methodType = 2`）

`tokenIn` 必须是 USDT。不进 Curve。

```
quote（只读）
    │
USDT.approve(Router, amountIn)
    │
execute{value: nativeFee}  methodType=2
    │
扣 2 bps → USDT 直接 send → 波场 USDT
```

| 顺序 | 动作 | 签名 |
|---|---|---|
| 0 | `quote` → `minAmountLD`（`outAmount` 链下打折）、`nativeFee` 原样回填 | 否 |
| 1 | `USDT.approve(Router, amountIn)` | 是 |
| 2 | `execute methodType=2`：扣 2 bps → USDT 直接 `send` | 是 |

`destChainId`：`30420`（LZ EID）或 `728126428`。`msg.value` 必须等于 `nativeFee`（wei），不退多余 ETH。

---

## 6. 合约与通道

| 名 | 链 | 地址 / 值 |
|---|---|---|
| `StablecoinBridgeTron` | 波场 | [`TMgkQyjZb11XJBVH2aqnKrxhot4erYduV7`](https://tronscan.org/contract/TMgkQyjZb11XJBVH2aqnKrxhot4erYduV7/code)（hex `0x8084a8E9C8508c4918e23ae16Df06e061BcA7485`）；旧 `TG1tdbbj…` / `TTF3ja…` 废弃 |
| `StablecoinBridgeRouter` | 以太坊 | [`0xcda2c4eaC941F9d4b6003bCeEbF3d2C5805AD121`](https://etherscan.io/address/0xcda2c4eac941f9d4b6003bceebf3d2c5805ad121#code)；旧 `0x4A760E…` / `0x0794…` 废弃 |
| Curve 3pool | 以太坊 | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` |
| UsdtOFT | 以太坊 | `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0` |
| UsdtOFT | 波场 peer | `0x3a08F76772e200653bB55c2a92998DAcA62e0e97`（`TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt`） |
| 波场 USDT | 波场 | `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t` |
| 以太坊 USDT | 以太坊 | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| 以太坊 USDC | 以太坊 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| 协议费 | Router / BridgeTron | `2 bps`（只兑、兑后跨、只跨都扣） |
| Curve 下限 | Router | `minAmountOut` → `Slippage`（UI「滑点」） |
| OFT 到账下限 | 两边入口 | `minAmountLD` → `OftSlippage`（`oftToleranceBps` 链下打折；**不算 UI 总滑点**） |
| LZ EID 以太坊 | | `30101` |
| LZ EID 波场 | | `30420` |

不要 `approve` UsdtOFT。走我们收费（只兑 / 兑后跨 / 直跨）只 `approve` Router。不经过我们、直对官方池才 `approve` 3pool。波场侧不要做 swap。

---

## 7. 对接注意

- 询价到上链之间池 / Mesh 费会变；过期重新 `quote`。`minAmountLD` / `nativeFee` / `msg.value` 用当次报价（`minAmountLD` 为打折后下限）。
- UI：「滑点」只对应 Curve `minAmountOut`；跨链 `oftToleranceBps` → `minAmountLD` 单独默认即可，不要合成总滑点。
- `send` 之后不跟踪；到账按 UsdtOFT / LayerZero / Mesh，有延迟。
- LayerZero 若退多余跨链费，退到 `msg.sender`，不是跨链合约。
- 协议费留在合约内，不打给用户；展示到账用 `quote.outAmount`。
- 部署后 `setFeeRecipient` 再 `claimFee`。
- **波场** [`TMgkQyjZb…`](https://tronscan.org/contract/TMgkQyjZb11XJBVH2aqnKrxhot4erYduV7/code)；**以太坊** [`0xcda2c4ea…`](https://etherscan.io/address/0xcda2c4eac941f9d4b6003bceebf3d2c5805ad121#code)（均为 `minAmountLD` + `OftSlippage` 版本）。
