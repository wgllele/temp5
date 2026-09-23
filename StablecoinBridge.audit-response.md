# StablecoinBridge 审计回应

按 **最低 gas** 设计。核心兑换 / 跨链无问题。不为教科书项加检查或重部署。

| 意见 | 结论 | 原因 |
|---|---|---|
| ETH→波场 `to` 去掉 `0x41` | **驳回** | 现编码 `0+0x41+20字节` 是 UsdtOFT / T 地址约定；去掉会到错地址。波场→ETH 才左垫 20 字节 |
| ERC20 检查返回 `bool` | **不改** | 白名单币；USDT 成功无返回值（只认 `true` 会挂 USDT）；USDC 等失败会 revert。SafeERC20 每笔多几百～两千 gas |
| `_balanceOf` 查返回长度 | **不改** | 正式 token 都返回 32 字节；多分支无用户资金收益 |
| 增加 `pause` | **不加** | 多一次 `SLOAD`；异常时交易自己 revert；前端下线即可 |
| 两步移交 owner | **不改** | 已禁 `address(0)`；属运维习惯 |
| `claimFee` 可提全部资产 | **保持** | 即 owner 救援 / 提现，NatSpec 已写 |
| 重入、滑点、链/币限制、OFT ABI、`msg.value==nativeFee` 等 | **同意** | 核心路径无问题 |
