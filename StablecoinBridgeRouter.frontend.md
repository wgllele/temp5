# StablecoinBridgeRouter 前端对接

面向钱包 / DApp / 后台发交易。主网参数与业务流程见 [StablecoinBridgeRouter.md](./StablecoinBridgeRouter.md)。

**主网 Router：** `0x4A760E4c0Af6F369E07A97C5ED75E626c1369070`（Ethereum `chainId = 1`）  
**旧地址 `0x0794…` ABI 已废弃**，不要再用 `feeMode` / `swapFee` / 结构体 `SwapParam`。

前端只需调：**ERC20 `approve` + `quote`（eth_call）+ `execute`（发交易）**。不要调 UsdtOFT、不要调 Curve。

---

## 1. 用户能做什么

| 产品动作 | `methodType` | `tokenIn` → 终点 |
|---|---|---|
| 以太坊内兑换稳定币 | `0` | `tokenOut` 转到 `recipient`（可填 `0x0` = 当前钱包） |
| 先兑成 USDT 再跨到波场 | `1` | 波场 USDT（OFT） |
| 以太坊 USDT 直接跨到波场 | `2` | 波场 USDT（OFT） |

协议费固定 **2 bps**：`fee = amountIn * 2 / 10000`，从 `tokenIn` 先扣，留在 Router，不打给用户。展示「到账」用 `quote` 的 `outAmount`，不要自己用 1:1 减费当兑出。

---

## 2. 常量（写进配置即可）

```ts
export const ROUTER = "0x4A760E4c0Af6F369E07A97C5ED75E626c1369070" as const;
export const CHAIN_ID = 1;

export const PROTOCOL_FEE_BPS = 2n;
export const BPS = 10_000n;
export const OFT_MIN_BPS = 9_900n; // 跨链 destAmount 不得低于成交时 quoteOFT 的 99%

export const LZ_EID_TRON = 30420n;
export const TRON_CHAIN_ID = 728126428n; // destChainId 填二者之一即可

export const METHOD_SWAP = 0n;
export const METHOD_SWAP_BRIDGE = 1n;
export const METHOD_BRIDGE = 2n;

export const TYPE_3POOL = 0n;       // DAI / USDC / USDT
export const TYPE_USDC_USDT = 1n;   // NG USDC↔USDT，小额通常更好
export const TYPE_PYUSD_USDC = 2n;
export const TYPE_CRVUSD_USDC = 3n;
export const TYPE_USDC_RLUSD = 4n;

export const TOKENS = {
  DAI:    { address: "0x6B175474E89094C44Da98b954EedeAC495271d0F", decimals: 18 },
  USDC:   { address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6 },
  USDT:   { address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6 },
  PYUSD:  { address: "0x6c3ea9036406852006290770BEdFcAbA0e23A0e8", decimals: 6 },
  crvUSD: { address: "0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E", decimals: 18 },
  RLUSD:  { address: "0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD", decimals: 18 },
} as const;
```

白名单只有上表。其它地址 `UnknownToken`。`methodType=2` 时 `tokenIn` 必须是 USDT。

---

## 3. ABI（人类可读）

```ts
export const ROUTER_ABI = [
  "function quote(uint256 swapType, uint256 methodType, address tokenIn, address tokenOut, address recipient, uint256 amountIn, uint256 destChainId, address destToken) view returns (uint256 outAmount, uint256 nativeFee)",
  "function execute(uint256 swapType, uint256 methodType, address tokenIn, address tokenOut, address recipient, uint256 amountIn, uint256 minAmountOut, uint256 destChainId, address destToken, uint256 destAmount, uint256 nativeFee) payable returns (uint256 outAmount)",
  "function PROTOCOL_FEE_BPS() view returns (uint256)",
  "function OFT_MIN_BPS() view returns (uint256)",
  "function USDT() view returns (address)",
  "event FeeCharged(address indexed token, address indexed holder, uint256 fee)",
  "event Swap(address indexed sender, address indexed recipient, address indexed pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)",
  "event Bridge(address indexed sender, address indexed recipient, address token, uint256 amount, uint256 destChainId)",
] as const;

export const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
] as const;
```

JSON ABI 也可从编译产物 `StablecoinBridgeRouter.json` 截取。viem 把上面字符串交给 `parseAbi([...])`。

---

## 4. 波场收款地址（最容易填错）

跨链 `recipient` **不是** `T…` 字符串，也 **不是** 带 `41` 的 21 字节。

1. 用户输入 Base58 `T…`。
2. Base58Check 解码得到 21 字节：`0x41` + 20 字节体 +（校验已在解码时验证）。
3. **丢掉 `0x41`**，剩下 20 字节当成 Ethereum `address` 传给 `quote` / `execute`。
4. 合约会再拼成 OFT 的 `bytes32`：`11 字节 0 + 0x41 + 20 字节`。

```ts
import bs58check from "bs58check";
import { getAddress, type Address } from "viem";

/** T… → 0x + 20 字节（checksum address） */
export function tronBase58ToRecipient(tAddr: string): Address {
  const raw = bs58check.decode(tAddr); // 21 bytes
  if (raw.length !== 21 || raw[0] !== 0x41) {
    throw new Error("not a Tron T-address");
  }
  return getAddress(`0x${Buffer.from(raw.subarray(1)).toString("hex")}`);
}
```

- 跨链：`recipient` **禁止** `0x000…0`（`ZeroAddress`）。
- 不要把用户的以太坊地址原样塞进跨链 `recipient`：会变成「同 20 字节」的波场地址，币到不了 ETH 钱包。
- 只兑（`methodType=0`）：`recipient` 用以太坊地址；`0x0` 表示打给 `msg.sender`。

---

## 5. 选池 `swapType`

合约**不会**按金额自动选池。发交易前对同一组参数只改 `swapType`，并行 `eth_call quote`，取 **`outAmount` 更大** 的。

| 交易对 | 建议比较的 `swapType` |
|---|---|
| USDC ↔ USDT | `0` 与 `1` |
| DAI ↔ USDC / DAI ↔ USDT | 只能 `0` |
| PYUSD ↔ USDC | `2` |
| crvUSD ↔ USDC | `3` |
| RLUSD ↔ USDC | `4` |

`methodType=2`（USDT 直跨）不走 Curve，`swapType` 可填 `0`，合约忽略池。

经验：小额 USDC↔USDT 常是 NG（`1`）更好；大额为防浅池可仍选 3pool（`0`）。**以当次 quote 为准。**

---

## 6. 流程

### 6.1 只兑（以太坊内）

```
1. 选 tokenIn / tokenOut / amountIn / recipient
2. 并行 quote(swapType=…) → 选最大 outAmount
3. minAmountOut = outAmount * (10000 - slippageBps) / 10000
   建议 slippageBps：小额 10～30；波动大或金额大 50～100
4. 若 allowance < amountIn：USDT 先 approve(Router, 0) 再 approve(Router, amountIn)
   其它币可直接 approve(Router, amountIn)
5. execute({ …, minAmountOut, destChainId: 0 或任意, destToken: 0, destAmount: 0, nativeFee: 0, value: 0 })
```

`quote` 的 `nativeFee` 为 `0`。`execute` 的 **`msg.value` 必须为 0**，多带 1 wei 也会 `NativeFeeMismatch`。

只兑时 `destChainId` / `destToken` 不参与校验（`methodType=0` 提前 return）。建议统一填 `destChainId = 728126428`、`destToken = 0x0`，少开分支。

### 6.2 跨链（methodType 1 或 2）

```
1. 解析波场 T 地址 → recipient（20 字节）
2. destChainId = 728126428 或 30420
3. destToken = 0x0 或 USDT（非 0 必须是 USDT）
4. methodType=1：tokenOut 必须是 USDT；先 quote 比池
   methodType=2：tokenIn 必须是 USDT；tokenOut 建议填 USDT
5. quote → destAmount = outAmount，nativeFee 原样保存
6. minAmountOut：methodType=1 按兑出 USDT 留滑点（可用 outAmount 的 99% 仅作 Curve；
   跨链真正卡的是 destAmount ≥ 成交时 OFT 到账的 99%）
   methodType=2：minAmountOut 填 0 即可
7. approve(Router, amountIn)（USDT 先置 0）
8. 钱包 value = nativeFee（Wei，必须相等，不退零）
9. execute(… destAmount, nativeFee) { value: nativeFee }
```

**`destAmount` / `nativeFee` 必须用当次 `quote` 的返回值，不要手改。**  
询价到签名之间池/跨链费会变：`minAmountOut` 防 Curve；`destAmount` 相对成交时 `quoteOFT` 允许差到 1%（`OFT_MIN_BPS`）。过期请重新 `quote` 再发。

用户钱包需要：

- `tokenIn` 余额 ≥ `amountIn`
- ETH：gas +（跨链时）`nativeFee`（量级约 0.00x ETH，以 quote 为准）

LayerZero 若退多余跨链费，退到 **`msg.sender`（当前钱包）**，不是 Router。

---

## 7. 调用示例（viem）

```ts
import { parseUnits, zeroAddress, type Address, type Hex } from "viem";

const fee = (amountIn: bigint) => (amountIn * 2n) / 10_000n;

async function quoteBest(args: {
  methodType: bigint;
  tokenIn: Address;
  tokenOut: Address;
  recipient: Address;
  amountIn: bigint;
  destChainId: bigint;
  swapTypes: bigint[];
}) {
  const rows = await Promise.all(
    args.swapTypes.map((swapType) =>
      publicClient.readContract({
        address: ROUTER,
        abi: ROUTER_ABI,
        functionName: "quote",
        args: [
          swapType,
          args.methodType,
          args.tokenIn,
          args.tokenOut,
          args.recipient,
          args.amountIn,
          args.destChainId,
          zeroAddress,
        ],
      }).then(([outAmount, nativeFee]) => ({ swapType, outAmount, nativeFee }))
    )
  );
  return rows.reduce((a, b) => (b.outAmount > a.outAmount ? b : a));
}

async function swapOnEth(params: {
  tokenIn: Address;
  tokenOut: Address;
  amountHuman: string;
  decimals: number;
  recipient: Address; // 或 zeroAddress
  slippageBps: bigint;
}) {
  const amountIn = parseUnits(params.amountHuman, params.decimals);
  const q = await quoteBest({
    methodType: METHOD_SWAP,
    tokenIn: params.tokenIn,
    tokenOut: params.tokenOut,
    recipient: params.recipient,
    amountIn,
    destChainId: TRON_CHAIN_ID,
    swapTypes: [TYPE_3POOL, TYPE_USDC_USDT], // 按交易对裁剪
  });
  const minAmountOut = (q.outAmount * (10_000n - params.slippageBps)) / 10_000n;

  await ensureApprove(params.tokenIn, amountIn);

  const hash = await walletClient.writeContract({
    address: ROUTER,
    abi: ROUTER_ABI,
    functionName: "execute",
    args: [
      q.swapType,
      METHOD_SWAP,
      params.tokenIn,
      params.tokenOut,
      params.recipient,
      amountIn,
      minAmountOut,
      TRON_CHAIN_ID,
      zeroAddress,
      0n,
      0n,
    ],
    value: 0n,
  });
  return hash;
}

async function bridgeToTron(params: {
  methodType: 1n | 2n;
  tokenIn: Address;
  amountIn: bigint;
  tronT: string;
  slippageBps: bigint; // 仅 methodType=1 的 Curve
}) {
  const recipient = tronBase58ToRecipient(params.tronT);
  const tokenOut = TOKENS.USDT.address;
  const swapTypes = params.methodType === 2n ? [TYPE_3POOL] : [TYPE_3POOL, TYPE_USDC_USDT];
  const q = await quoteBest({
    methodType: params.methodType,
    tokenIn: params.tokenIn,
    tokenOut,
    recipient,
    amountIn: params.amountIn,
    destChainId: TRON_CHAIN_ID,
    swapTypes,
  });
  const minAmountOut =
    params.methodType === 2n ? 0n : (q.outAmount * (10_000n - params.slippageBps)) / 10_000n;

  await ensureApprove(params.tokenIn, params.amountIn);

  return walletClient.writeContract({
    address: ROUTER,
    abi: ROUTER_ABI,
    functionName: "execute",
    args: [
      q.swapType,
      params.methodType,
      params.tokenIn,
      tokenOut,
      recipient,
      params.amountIn,
      minAmountOut,
      TRON_CHAIN_ID,
      zeroAddress,
      q.outAmount, // destAmount
      q.nativeFee,
    ],
    value: q.nativeFee, // 必须相等
  });
}
```

USDT `approve`：

```ts
async function ensureApprove(token: Address, amountIn: bigint) {
  const owner = walletClient.account.address;
  const allowance = await publicClient.readContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: [owner, ROUTER],
  });
  if (allowance >= amountIn) return;
  if (token.toLowerCase() === TOKENS.USDT.address.toLowerCase() && allowance !== 0n) {
    await walletClient.writeContract({
      address: token,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [ROUTER, 0n],
    });
  }
  await walletClient.writeContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [ROUTER, amountIn],
  });
}
```

授权对象永远是 **Router**，不是 OFT、不是 Curve。

---

## 8. UI 展示建议

| 字段 | 算法 |
|---|---|
| 协议费 | `amountIn * 2 / 10000`（`tokenIn` 最小单位） |
| 预计到账 | `quote.outAmount`（只兑 = `tokenOut`；跨链 = 波场预计到账，已含 Mesh） |
| 跨链网络费 | `formatEther(nativeFee)` ETH，需随交易垫付 |
| `minAmountOut` 文案 | 「最少兑出（Curve 滑点）」；跨链另有 1% OFT 下限，不必再让用户填 `destAmount` |

成交后：

- 只兑：看 `Swap.amountOut`，以及 `tokenOut` Transfer 到 `recipient`。
- 跨链：`Bridge.amount` = 目的链预计到账；以太坊上 USDT 已进 OFT，波场到账有 LZ/Mesh 延迟。

`FeeCharged.fee` 是本笔协议费，`holder` 是 Router。

---

## 9. 常见 revert（给用户看的文案）

| 错误 | 何时 | 建议提示 |
|---|---|---|
| `NativeFeeMismatch(required, given)` | `msg.value` ≠ 只兑 0 / 跨链 `nativeFee` | 跨链请用最新报价的 ETH 网络费，不要改 value |
| `Slippage(amountOut, min)` | Curve 兑出或 OFT `destAmount` 过低 | 提高滑点或重新询价 |
| `UnknownDestChain` | `destChainId` 不是 30420 / 728126428 | 仅支持波场 |
| `ZeroAddress` | 跨链 `recipient` 为空 | 填写有效 T 地址 |
| `BridgeTokenMustBeUsdt` | 直跨非 USDT，或兑后跨 `tokenOut` 非 USDT，或 `destToken` 乱填 | 跨链资产仅为 USDT |
| `UnknownToken` / `UnknownPool` / `SameToken` | 币或池不匹配 | 检查交易对与 swapType |
| `ZeroAmount` | `amountIn` 或跨链 `destAmount` 为 0 | 金额无效 |
| `InvalidMethodType` | 不是 0/1/2 | — |
| `ExchangeFailed` | Curve `get_dy`/`exchange` 失败 | 池子或金额异常，换池重试 |
| ERC20 / USDT 失败 | 未授权、余额不足、黑名单 | 检查余额与 approve |

用 `viem` 的 `ContractFunctionRevertedError` / `errorName` 解码自定义错误。

模拟成交：`eth_call execute` 需要 state override（余额 + allowance）；跨链还要 `value = nativeFee`。一般前端只用 `quote` 即可。

---

## 10. 不要做的事

- 不要 `approve` UsdtOFT 或 Curve。
- 不要把 `quote.nativeFee` 加在 gasPrice 上；它是 `tx.value`。
- 不要多付 ETH 指望退款（Router **不退** `msg.value` 差额）。
- 不要传 `feeMode` / `swapFee` / `fillDeadline` / 结构体。
- 不要对接 `0x0794…`。
- 前端不要调 `setOwner` / `setFeeRecipient` / `claimFee`（仅管理员）。

---

## 11. 联调检查单

- [ ] `chainId === 1`，`to === 0x4A76…`
- [ ] USDT 二次 approve（非 0 → 先 0）
- [ ] USDC↔USDT 两次 `quote` 再选池
- [ ] 只兑 `value = 0`
- [ ] 跨链 T 地址去掉 `41`；`destAmount`/`nativeFee`/`value` 三相等（后两者与 quote 一致）
- [ ] 展示 2 bps 协议费 + `outAmount`
- [ ] 重新询价后再签名（报价超过数秒到几十秒建议刷新）
