import {
  Callout,
  Card,
  CardBody,
  CardHeader,
  Divider,
  Grid,
  H1,
  H2,
  H3,
  Pill,
  Row,
  Stack,
  Stat,
  Table,
  Text,
  useCanvasState,
  useHostTheme,
} from "cursor/canvas";

type PathId = "tron-to-eth" | "eth-to-tron";
type EthToTronMode = "swap-bridge" | "direct";

export default function TronEthCrosschainArchitecture() {
  const [rawPath, setPath] = useCanvasState<string>("path", "tron-to-eth");
  const path: PathId = rawPath === "eth-to-tron" ? "eth-to-tron" : "tron-to-eth";
  const [ethMode, setEthMode] = useCanvasState<EthToTronMode>(
    "eth-to-tron-mode",
    "swap-bridge"
  );

  return (
    <Stack gap={22}>
      <Stack gap={6}>
        <H1>波场 ↔ 以太坊 跨链业务架构</H1>
        <Text tone="secondary">
          跨链两边都是 approve 我们的合约 + execute。以太坊→波场若要兑，走 Router（合约内调
          Curve）。波场→以太坊之后再兑，才走官方 3pool，不走我们的合约。
        </Text>
      </Stack>

      <Grid columns={4} gap={12}>
        <Stat value="2 次" label="用户签名（approve + 执行）" />
        <Stat value="2 bps" label="跨链合约协议费（从 tokenIn 先扣）" />
        <Stat value="只跨 USDT" label="跨链资产（波场不 swap）" />
        <Stat value="到账后再兑" label="官方 Curve，不走我们的合约" />
      </Grid>

      <Row gap={8} align="center">
        <Pill active={path === "tron-to-eth"} onClick={() => setPath("tron-to-eth")}>
          波场 → 以太坊
        </Pill>
        <Pill active={path === "eth-to-tron"} onClick={() => setPath("eth-to-tron")}>
          以太坊 → 波场
        </Pill>
      </Row>

      {path === "eth-to-tron" ? (
        <Row gap={8} align="center">
          <Text tone="secondary" size="small">
            回波场方式
          </Text>
          <Pill active={ethMode === "swap-bridge"} onClick={() => setEthMode("swap-bridge")}>
            先交易后跨链
          </Pill>
          <Pill active={ethMode === "direct"} onClick={() => setEthMode("direct")}>
            直接跨链
          </Pill>
        </Row>
      ) : null}

      <ArchitectureMap path={path} ethMode={ethMode} />

      <PathDetail path={path} ethMode={ethMode} />

      <Divider />

      <H2>跨链路径对照</H2>
      <Table
        headers={["路径", "用户 approve 对象", "第二笔签名", "合约内部", "资金终点"]}
        rows={[
          [
            "波场 → 以太坊",
            "StablecoinBridgeTron",
            "execute（垫 nativeFee / sun）",
            "扣 2 bps → UsdtOFT.send",
            "以太坊 USDT",
          ],
          [
            "以太坊 → 波场 · 先兑后跨",
            "StablecoinBridgeRouter",
            "execute{value: nativeFee} methodType=1",
            "扣 2 bps → 合约内 Curve 兑成 USDT → UsdtOFT.send",
            "波场 USDT",
          ],
          [
            "以太坊 → 波场 · 直跨",
            "StablecoinBridgeRouter",
            "execute{value: nativeFee} methodType=2",
            "扣 2 bps → USDT 直接 send",
            "波场 USDT",
          ],
        ]}
      />

      <Callout tone="warning" title="USDT 授权例外">
        产品口径是两次签名。若 USDT 上已有非 0 授权，须先 approve(0) 再 approve(amount)，会多一笔。quote /
        get_dy 是 eth_call，不占签名。
      </Callout>

      <H2>合约与通道</H2>
      <Grid columns={2} gap={16}>
        <Card>
          <CardHeader>波场入口 · StablecoinBridgeTron</CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text>
                只跨链，不 swap。拉 TRC20 USDT，扣 2 bps 留在合约，再 UsdtOFT.send 到以太坊。
              </Text>
              <Text tone="secondary" size="small">
                USDT TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t · destChainId 30101 或 1 · 用户
                approve 本合约，不是 OFT
              </Text>
            </Stack>
          </CardBody>
        </Card>
        <Card>
          <CardHeader>以太坊入口 · StablecoinBridgeRouter</CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text>
                主网 0x4A760E4c0Af6F369E07A97C5ED75E626c1369070。ETH→波场的兑和跨都走它。
                methodType 1 合约内调 Curve 再跨；2 直跨。用户不要直接调 Curve / UsdtOFT。
              </Text>
              <Text tone="secondary" size="small">
                UsdtOFT 0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0 · LZ 波场 EID 30420
              </Text>
            </Stack>
          </CardBody>
        </Card>
      </Grid>

      <Stack gap={8}>
        <H3>到账后再兑</H3>
        <Text>
          总图里从以太坊用户钱包向下那一支：官方池 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7，
          approve + exchange，不走 Router。回波场要兑则走 Router methodType=1，不要先走这支再跨。
        </Text>
      </Stack>
    </Stack>
  );
}

function PathDetail({
  path,
  ethMode,
}: {
  path: PathId;
  ethMode: EthToTronMode;
}) {
  if (path === "tron-to-eth") {
    return (
      <Stack gap={10}>
        <H2>波场 → 以太坊</H2>
        <Text tone="secondary">
          波场侧没有兑换。到账后若要 USDC，沿总图从以太坊用户钱包再往下走官方 Curve。
        </Text>
        <Table
          headers={["顺序", "动作", "签名"]}
          rows={[
            ["0", "quote(recipient, amountIn, destChainId, destToken) → outAmount, nativeFee", "否"],
            ["1", "USDT.approve(BridgeTron, amountIn)；非 0 授权先置 0", "是"],
            [
              "2",
              "BridgeTron.execute{value: nativeFee}：拉币 → 扣 2 bps → UsdtOFT.send 到以太坊地址",
              "是",
            ],
            ["—", "LayerZero / Mesh 到账以太坊 USDT（有延迟）", "否"],
          ]}
        />
      </Stack>
    );
  }

  const swapFirst = ethMode === "swap-bridge";
  return (
    <Stack gap={10}>
      <H2>{swapFirst ? "以太坊 → 波场 · 先交易后跨链" : "以太坊 → 波场 · 直接跨链"}</H2>
      <Text tone="secondary">
        {swapFirst
          ? "swap 走我们的 Router，不是官方池入口。用户只 approve Router；Curve 由合约在同一笔 execute 里调用。"
          : "tokenIn 必须是 USDT。Router 扣费后直接 UsdtOFT.send，不进 Curve。"}
      </Text>
      <Table
        headers={["顺序", "动作", "签名"]}
        rows={
          swapFirst
            ? [
                ["0", "quote 比池（3pool / NG），记下 outAmount、nativeFee", "否"],
                ["1", "tokenIn.approve(Router, amountIn)", "是"],
                [
                  "2",
                  "execute methodType=1：扣 2 bps → Curve 兑成 USDT → UsdtOFT.send 到波场 T 地址（20 字节体）",
                  "是",
                ],
              ]
            : [
                ["0", "quote → destAmount、nativeFee 原样回填", "否"],
                ["1", "USDT.approve(Router, amountIn)", "是"],
                ["2", "execute methodType=2：扣 2 bps → USDT 直接 send 到波场", "是"],
              ]
        }
      />
    </Stack>
  );
}

function ArchitectureMap({
  path,
  ethMode,
}: {
  path: PathId;
  ethMode: EthToTronMode;
}) {
  const t = useHostTheme();
  const on = (active: boolean) => ({
    fill: active ? t.fill.tertiary : t.fill.secondary,
    stroke: active ? t.accent.primary : t.stroke.secondary,
    title: active ? t.text.primary : t.text.secondary,
    sub: active ? t.text.secondary : t.text.tertiary,
  });

  const tronUser = on(path === "tron-to-eth" || path === "eth-to-tron");
  const tronBridge = on(path === "tron-to-eth");
  const oft = on(path === "tron-to-eth" || path === "eth-to-tron");
  const ethUser = on(true);
  const router = on(path === "eth-to-tron");
  const post = on(path === "tron-to-eth");
  const lzRight = path === "tron-to-eth";
  const lzLeft = path === "eth-to-tron";
  const postStroke = path === "tron-to-eth" ? t.accent.primary : t.stroke.tertiary;

  return (
    <div
      style={{
        background: t.bg.elevated,
        border: `1px solid ${t.stroke.secondary}`,
        padding: 16,
      }}
    >
      <svg viewBox="0 0 980 540" width="100%" role="img" aria-label="波场与以太坊跨链及到账后再兑">
        <text x="24" y="24" fill={t.text.tertiary} fontSize="12">
          波场
        </text>
        <text x="400" y="24" fill={t.text.tertiary} fontSize="12">
          LayerZero / USDT0 Mesh
        </text>
        <text x="720" y="24" fill={t.text.tertiary} fontSize="12">
          以太坊
        </text>

        <Box x={24} y={40} w={250} h={66} c={tronUser} title="用户钱包" sub="TRC20 USDT" />
        <Box x={24} y={136} w={250} h={70} c={tronBridge} title="我们的跨链合约" sub="BridgeTron · 只跨不兑 · 扣 2 bps" />
        <Box x={24} y={236} w={250} h={66} c={oft} title="UsdtOFT" sub="send / 到账" />

        <Box x={706} y={40} w={250} h={66} c={ethUser} title="用户钱包" sub="USDT · 含波场到账" />
        <Box
          x={706}
          y={136}
          w={250}
          h={78}
          c={router}
          title="我们的跨链合约"
          sub={
            path === "eth-to-tron" && ethMode === "direct"
              ? "Router · methodType=2 直跨"
              : "Router · methodType=1 合约内兑再跨"
          }
        />

        <Box x={706} y={360} w={250} h={70} c={post} title="Curve 官方 3pool" sub="① approve  ② exchange" />
        <Box x={706} y={456} w={250} h={66} c={post} title="以太坊 USDC 等" sub="仍留在以太坊 · 不走 Router" />

        <Arrow
          x1={149}
          y1={106}
          x2={149}
          y2={136}
          color={path === "tron-to-eth" ? t.accent.primary : t.stroke.secondary}
          label="① approve  ② execute"
          labelX={158}
          labelY={126}
          theme={t}
          show
        />
        <Arrow
          x1={149}
          y1={206}
          x2={149}
          y2={236}
          color={path === "tron-to-eth" ? t.accent.primary : t.stroke.secondary}
          label=""
          labelX={0}
          labelY={0}
          theme={t}
          show
        />
        <Arrow
          x1={831}
          y1={106}
          x2={831}
          y2={136}
          color={path === "eth-to-tron" ? t.accent.primary : t.stroke.secondary}
          label="① approve  ② execute"
          labelX={848}
          labelY={126}
          theme={t}
          show
        />

        <line
          x1={274}
          y1={171}
          x2={706}
          y2={171}
          stroke={lzLeft || lzRight ? t.accent.primary : t.stroke.tertiary}
          strokeWidth={lzLeft || lzRight ? 2 : 1}
        />
        <text x={360} y={162} fill={t.text.tertiary} fontSize="11">
          波场 USDT ↔ 以太坊 USDT
        </text>

        <polyline
          points="706,73 640,73 640,395 706,395"
          fill="none"
          stroke={postStroke}
          strokeWidth={path === "tron-to-eth" ? 2 : 1}
        />
        <text x={430} y={330} fill={path === "tron-to-eth" ? t.accent.primary : t.text.tertiary} fontSize="11">
          跨链已结束（可选，不走 Router）
        </text>
        <line x1={831} y1={430} x2={831} y2={456} stroke={postStroke} strokeWidth={path === "tron-to-eth" ? 2 : 1} />
      </svg>
    </div>
  );
}

function Box({
  x,
  y,
  w,
  h,
  c,
  title,
  sub,
}: {
  x: number;
  y: number;
  w: number;
  h: number;
  c: { fill: string; stroke: string; title: string; sub: string };
  title: string;
  sub: string;
}) {
  return (
    <g>
      <rect x={x} y={y} width={w} height={h} fill={c.fill} stroke={c.stroke} />
      <text x={x + 14} y={y + 28} fill={c.title} fontSize="14" fontWeight={600}>
        {title}
      </text>
      <text x={x + 14} y={y + 50} fill={c.sub} fontSize="12">
        {sub}
      </text>
    </g>
  );
}

function Arrow({
  x1,
  y1,
  x2,
  y2,
  color,
  label,
  labelX,
  labelY,
  theme,
  show,
}: {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  color: string;
  label: string;
  labelX: number;
  labelY: number;
  theme: ReturnType<typeof useHostTheme>;
  show: boolean;
}) {
  if (!show) return null;
  return (
    <g>
      <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={color} strokeWidth={2} />
      {label ? (
        <text x={labelX} y={labelY} fill={theme.text.secondary} fontSize="11">
          {label}
        </text>
      ) : null}
    </g>
  );
}
