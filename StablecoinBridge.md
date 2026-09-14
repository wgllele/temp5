# 波场 ↔ 以太坊 跨链业务架构

跨链两边都是 **approve 我们的合约 + execute**，两次签名。`quote` 为只读。协议费固定 **2 bps**（从 `tokenIn` 先扣，留在合约，owner `claimFee`）。跨链资产仅为 **USDT**，通道为 UsdtOFT / LayerZero V2 Legacy Mesh。

**谁做 swap：**

- **以太坊 → 波场** 需要兑换：走我们的 `StablecoinBridgeRouter`（`methodType=1`），用户不直接调 Curve。
- **波场 → 以太坊之后** 再兑换：不走我们的合约，用户直接对 Curve 官方池 `approve` + `exchange`。
- 波场侧不 swap。

合约文档：[StablecoinBridgeTron](./StablecoinBridgeTron.md)（波场→ETH，只跨）· [StablecoinBridgeRouter](./StablecoinBridgeRouter.md)（ETH→波场，兑和跨都走它）· [前端对接](./StablecoinBridgeRouter.frontend.md) · 交互图：[StablecoinBridge.canvas.tsx](./StablecoinBridge.canvas.tsx)

---

## 1. 总图

一张图：上面是双向跨链，到账 USDT 再往下才是官方 Curve（可选，不走 Router）。

```
波场                                              以太坊
┌─────────────────────┐                          ┌─────────────────────┐
│ 用户钱包             │                          │ 到账 USDT            │
│ TRC20 USDT          │                          └──────────┬──────────┘
└──────────┬──────────┘                                     │
           │ ① approve                                      │
           │ ② execute                       回波场 ①②      │ 跨链已结束（可选）
           ▼                                    │           │ 不走 Router
┌─────────────────────┐                         ▼           │
│ 我们的跨链合约       │                          ┌─────────┴───────────┐
│ BridgeTron          │◄════ LayerZero / ═══════►│ 我们的跨链合约       │
│ 只跨，不兑，扣 2 bps │     USDT0 Mesh           │ Router              │
└──────────┬──────────┘                          │ 1 合约内 Curve 再跨 │
           │                                     │ 2 USDT 直跨         │
           ▼                                     └──────────┬──────────┘
┌─────────────────────┐                                     │
│ UsdtOFT             │                                     ▼
└─────────────────────┘                                波场收款 USDT
           │
           │  波场 USDT ──send──► 以太坊到账 USDT
           │  以太坊 USDT ──send──► 波场收款
           │
           │                                     ┌─────────────────────┐
           └────────────────────────────────────►│ Curve 官方 3pool     │
                                                 │ ① approve 3pool     │
                                                 │ ② exchange          │
                                                 └──────────┬──────────┘
                                                            ▼
                                                      以太坊 USDC 等
                                                      （仍留在以太坊）
```

| 路径 | 用户 approve 对象 | 第二笔签名 | swap | 资金终点 |
|---|---|---|---|---|
| 波场 → 以太坊 | `StablecoinBridgeTron` | `execute`（垫 `nativeFee` / sun） | 无 | 上图「到账 USDT」 |
| 到账后再兑（上图向下） | Curve 3pool 官方池 | `exchange(i,j,dx,min_dy)` | **不走我们的合约** | 仍在以太坊 |
| 以太坊 → 波场 · 先兑后跨 | `StablecoinBridgeRouter` | `execute{value: nativeFee}` `methodType=1` | **走我们的合约**，Router 内调 Curve | 波场 USDT |
| 以太坊 → 波场 · 直跨 | `StablecoinBridgeRouter` | `execute{value: nativeFee}` `methodType=2` | 无 | 波场 USDT |

产品口径是两次签名。USDT 上若已有非 0 授权，须先 `approve(0)` 再 `approve(amount)`，会多一笔。`quote` / `get_dy` 不占签名。

---

## 2. 波场 → 以太坊

波场侧**没有兑换**。到账以太坊后若还要换成 USDC 等，再走 §3（官方 Curve，不是 Router）。

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
| 2 | `execute{value: nativeFee}`：拉币 → 扣 2 bps → `UsdtOFT.send` 到以太坊地址 | 是 |
| — | LayerZero / Mesh 到账（有延迟） | 否 |

- `recipient` 填**以太坊** 20 字节地址，不要填波场 `T…`。
- `destChainId`：`30101`（LZ EID）或 `1`。
- `nativeFee` / `msg.value` 单位是 TRX **sun**。
- 用户 `approve` 本合约，不是 OFT。

---

## 3. 波场到以太坊之后再 swap（不走我们的合约）

即总图里从「到账 USDT」再往下的那一支。跨链已经结束。用户对 **Curve 官方 3pool** 授权并成交，**不要** `approve` Router。

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

## 4. 以太坊 → 波场（兑和跨都走我们的合约）

用户只对 Router 签两笔。需要 swap 时由 Router 在同一笔 `execute` 里调 Curve，**用户不要先单独调 3pool**。

### 4.1 先交易后跨链（`methodType = 1`）

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
| 0 | `quote` 比池（3pool / NG），记下 `outAmount`、`nativeFee` | 否 |
| 1 | `tokenIn.approve(Router, amountIn)`（不是 3pool、不是 OFT） | 是 |
| 2 | `execute methodType=1`：扣 2 bps → 合约内 Curve → `UsdtOFT.send` | 是 |

`tokenOut` 必须是 USDT。跨链 `recipient` 为去掉 `41` 的波场 20 字节体（不要填 `T…` 字符串，也不要填带 `41` 的 21 字节）。

### 4.2 直接跨链（`methodType = 2`）

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
| 0 | `quote` → `destAmount`、`nativeFee` 原样回填 | 否 |
| 1 | `USDT.approve(Router, amountIn)` | 是 |
| 2 | `execute methodType=2`：扣 2 bps → USDT 直接 `send` | 是 |

`destChainId`：`30420`（LZ EID）或 `728126428`。`msg.value` 必须等于 `nativeFee`（wei），不退多余 ETH。

---

## 5. 合约与通道

| 名 | 链 | 地址 / 值 |
|---|---|---|
| `StablecoinBridgeTron` | 波场 | 见源码；部署后填主网地址 |
| `StablecoinBridgeRouter` | 以太坊 | `0x4A760E4c0Af6F369E07A97C5ED75E626c1369070` |
| Curve 3pool | 以太坊 | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` |
| UsdtOFT | 以太坊 / 波场 peer | `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0` |
| 波场 USDT | 波场 | `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t` |
| 以太坊 USDT | 以太坊 | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| 以太坊 USDC | 以太坊 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| 协议费 | 两边跨链合约 | `2 bps` |
| OFT 到账下限 | 两边跨链合约 | 成交时 `quoteOFT` 的 99% |
| LZ EID 以太坊 | | `30101` |
| LZ EID 波场 | | `30420` |

不要 `approve` UsdtOFT。ETH→波场的 swap 只 `approve` Router。波场→ETH 之后的 swap 只 `approve` Curve 官方池。波场侧不要做 swap。

---

## 6. 对接注意

- 询价到上链之间池 / Mesh 费会变；过期重新 `quote`。`destAmount` / `nativeFee` / `msg.value` 必须用当次 `quote` 原样回填。
- `send` 之后不跟踪；到账按 UsdtOFT / LayerZero / Mesh，有延迟。
- LayerZero 若退多余跨链费，退到 `msg.sender`，不是跨链合约。
- 协议费留在合约内，不打给用户；展示到账用 `quote.outAmount`。
