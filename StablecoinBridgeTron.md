# StablecoinBridgeTron

波场 → 以太坊，只跨 USDT，不 swap。与 `StablecoinBridgeRouter` 同目录；部署在波场主网。

`constructor(initOwner)`。费率固定 2 bps。先 `quote`，再 `execute{value: nativeFee}`（`nativeFee` 单位为 TRX **sun**）。`msg.value` 必须相等，不退多余 TRX。

## 常量

| 名 | 值 |
|---|---|
| USDT | `0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C`（TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t） |
| ETH_USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7`（仅 `destToken` 校验） |
| USDT_OFT | 波场 UsdtOFT。部署前用 ETH `0x1F748c…dfb0.peers(30420)` 核对 |
| destChainId | `30101`（LZ EID）或 `1` |
| recipient | 以太坊 20 字节地址（合约左垫 12 字节 0 成 `bytes32`） |

## 调用

```
quote(recipient, amountIn, destChainId, destToken) → (outAmount, nativeFee)
execute(recipient, amountIn, destChainId, destToken, destAmount, nativeFee) payable
```

- `destToken`：`0` 或 ETH USDT。
- `destAmount` / `nativeFee` / `msg.value` 用当次 `quote` 原样回填。
- 用户 `approve` 本合约（不是 OFT）。USDT 若已有非 0 授权，先 `approve(0)`。
- 协议费留在本合约，owner `setFeeRecipient` + `claimFee`。

治理：`setOwner` / `setFeeRecipient` / `claimFee`（`token=0` 提 TRX；`amount==1` 表示全部）。
