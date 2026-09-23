import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  ReferenceLine,
  XAxis,
  YAxis,
} from "recharts"

import { useChartHover } from "@/components/railwatch/chart-hover"
import {
  type ChartConfig,
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from "@/components/ui/chart"
import { ms } from "@/lib/format"
import type {
  DeployMarker,
  Percentile,
  SeriesPoint,
  SessionStatusPoint,
} from "@/types"

// Status vocabulary, same as the badges: ok is quiet grey so the amber and
// red slices are what the eye lands on; latency lines use the accent for
// the chosen percentile and a muted amber for the average.
const config = {
  count: { label: "OK", color: "var(--ok)" },
  errors: { label: "5xx", color: "var(--danger)" },
  client_errors: { label: "4xx", color: "var(--warning)" },
  p50: { label: "p50", color: "var(--primary)" },
  p95: { label: "p95", color: "var(--primary)" },
  p99: { label: "p99", color: "var(--primary)" },
  avg: { label: "avg", color: "var(--warning)" },
} satisfies ChartConfig

// Bucket width in ms, read off the data so the axis needs no page context:
// a minute chart labels ticks by time, a day chart by date.
function bucketWidth(data: { t: string }[]) {
  if (data.length < 2) return 0
  return new Date(data[1].t).getTime() - new Date(data[0].t).getTime()
}

const DAY = 24 * 60 * 60 * 1000

function tickFormatter(data: { t: string }[]) {
  const width = bucketWidth(data)
  const span =
    data.length > 1
      ? new Date(data[data.length - 1].t).getTime() -
        new Date(data[0].t).getTime()
      : 0
  if (width >= DAY || span > 2 * DAY)
    return (t: string) =>
      new Date(t).toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
      })
  return (t: string) =>
    new Date(t).toLocaleTimeString(undefined, {
      hour: "2-digit",
      minute: "2-digit",
    })
}

function stamp(t: string) {
  const d = new Date(t)
  return d.toLocaleString(undefined, {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  })
}

const axisTick = { fontSize: 10, fontFamily: "var(--font-mono)" }

// A line only joins neighbouring points, so a bucket with data between two
// quiet ones (common at a minute's width) would draw nothing. Mark those
// lone points with a dot; everything else stays a plain line. Recharts can
// call this with an index past the array it was built over (a live reload
// swapping in a shorter series mid-render did, LC-43), so neighbours are
// looked up defensively rather than assumed.
export function loneDot(
  data: Record<string, unknown>[],
  key: string,
  color: string,
) {
  const LoneDot = (props: { cx?: number; cy?: number; index?: number }) => {
    const { cx, cy, index } = props
    if (cx == null || cy == null || index == null) return <g key={index} />
    const before = data[index - 1]?.[key] ?? null
    const after = data[index + 1]?.[key] ?? null
    if (before != null || after != null) return <g key={index} />
    return <circle key={index} cx={cx} cy={cy} r={2} fill={color} />
  }
  return LoneDot
}

function markers(deploys: DeployMarker[] = []) {
  return deploys.map((d) => (
    <ReferenceLine
      key={d.deploy}
      x={new Date(d.at).toISOString()}
      stroke="var(--primary)"
      strokeDasharray="3 3"
      label={{
        value: d.ref,
        position: "insideTopRight",
        fontSize: 9,
        fill: "var(--primary)",
        fontFamily: "var(--font-mono)",
      }}
    />
  ))
}

// Recharts calls onMouseMove with the hovered point's x value as
// `activeLabel` (our bucket ISO timestamp) — feed that into ChartHoverProvider
// so a table elsewhere on the page can highlight the matching row.
function useBucketHover() {
  const { setHoveredKey } = useChartHover()
  return {
    onMouseMove: (state: { activeLabel?: string | number }) => {
      if (typeof state?.activeLabel === "string")
        setHoveredKey(state.activeLabel)
    },
    onMouseLeave: () => setHoveredKey(null),
  }
}

// Bucket-range caption under a chart, like Nightwatch's "02 Nov 18:00 UTC".
function Range({ data }: { data: { t: string }[] }) {
  if (data.length === 0) return null
  return (
    <div className="text-muted-foreground mt-1 flex justify-between font-mono text-[10px]">
      <span>{stamp(data[0].t)}</span>
      <span>{stamp(data[data.length - 1].t)}</span>
    </div>
  )
}

export function ThroughputChart({
  data,
  deploys,
  label = "Requests",
  className = "h-40",
}: {
  data: SeriesPoint[]
  deploys?: DeployMarker[]
  label?: string
  className?: string
}) {
  const cfg = { ...config, count: { ...config.count, label } }
  const hover = useBucketHover()
  const tick = tickFormatter(data)
  return (
    <div>
      <ChartContainer config={cfg} className={`${className} w-full`}>
        <BarChart
          data={data.map((d) => ({
            ...d,
            t: new Date(d.t).toISOString(),
            ok: Math.max(0, d.count - d.errors - d.client_errors),
          }))}
          barCategoryGap={2}
          onMouseMove={hover.onMouseMove}
          onMouseLeave={hover.onMouseLeave}
        >
          <CartesianGrid vertical={false} strokeDasharray="2 4" />
          <XAxis
            dataKey="t"
            tickFormatter={tick}
            tickLine={false}
            axisLine={false}
            minTickGap={40}
            tick={axisTick}
          />
          <YAxis
            width={36}
            tickLine={false}
            axisLine={false}
            tick={axisTick}
            tickFormatter={(v) => compact(Number(v))}
          />
          <ChartTooltip
            content={
              <ChartTooltipContent labelFormatter={(v) => stamp(String(v))} />
            }
          />
          <Bar
            dataKey="ok"
            name="count"
            fill="var(--color-count)"
            stackId="a"
          />
          <Bar
            dataKey="client_errors"
            fill="var(--color-client_errors)"
            stackId="a"
          />
          <Bar
            dataKey="errors"
            fill="var(--color-errors)"
            stackId="a"
            radius={[2, 2, 0, 0]}
          />
          {markers(deploys)}
        </BarChart>
      </ChartContainer>
      <Range data={data} />
    </div>
  )
}

// Release health's own vocabulary: sessions stacked by the worst status
// they reached, so a regression reads as amber and red eating the band.
const sessionConfig = {
  ok: { label: "ok", color: "var(--ok)" },
  errored: { label: "errored", color: "var(--warning)" },
  crashed: { label: "crashed", color: "var(--danger)" },
} satisfies ChartConfig

export function SessionStatusChart({
  data,
  deploys,
  className = "h-40",
}: {
  data: SessionStatusPoint[]
  deploys?: DeployMarker[]
  className?: string
}) {
  const hover = useBucketHover()
  const tick = tickFormatter(data)
  return (
    <div>
      <ChartContainer config={sessionConfig} className={`${className} w-full`}>
        <AreaChart
          data={data.map((d) => ({ ...d, t: new Date(d.t).toISOString() }))}
          onMouseMove={hover.onMouseMove}
          onMouseLeave={hover.onMouseLeave}
        >
          <CartesianGrid vertical={false} strokeDasharray="2 4" />
          <XAxis
            dataKey="t"
            tickFormatter={tick}
            tickLine={false}
            axisLine={false}
            minTickGap={40}
            tick={axisTick}
          />
          <YAxis
            width={36}
            tickLine={false}
            axisLine={false}
            tick={axisTick}
            tickFormatter={(v) => compact(Number(v))}
          />
          <ChartTooltip
            content={
              <ChartTooltipContent labelFormatter={(v) => stamp(String(v))} />
            }
          />
          {(["ok", "errored", "crashed"] as const).map((key) => (
            <Area
              key={key}
              dataKey={key}
              stackId="sessions"
              stroke={`var(--color-${key})`}
              fill={`var(--color-${key})`}
              fillOpacity={0.3}
              strokeWidth={1.25}
              isAnimationActive={false}
            />
          ))}
          {markers(deploys)}
        </AreaChart>
      </ChartContainer>
      <Range data={data} />
    </div>
  )
}

export function LatencyChart({
  data,
  deploys,
  percentile = "p95",
  className = "h-40",
}: {
  data: SeriesPoint[]
  deploys?: DeployMarker[]
  percentile?: Percentile
  className?: string
}) {
  const hover = useBucketHover()
  const tick = tickFormatter(data)
  const points = data.map((d) => ({ ...d, t: new Date(d.t).toISOString() }))
  return (
    <div>
      <ChartContainer config={config} className={`${className} w-full`}>
        <LineChart
          data={points}
          onMouseMove={hover.onMouseMove}
          onMouseLeave={hover.onMouseLeave}
        >
          <CartesianGrid vertical={false} strokeDasharray="2 4" />
          <XAxis
            dataKey="t"
            tickFormatter={tick}
            tickLine={false}
            axisLine={false}
            minTickGap={40}
            tick={axisTick}
          />
          <YAxis
            width={44}
            tickLine={false}
            axisLine={false}
            tick={axisTick}
            tickFormatter={(v) => ms(Number(v), 0)}
          />
          <ChartTooltip
            content={
              <ChartTooltipContent
                labelFormatter={(v) => stamp(String(v))}
                formatter={(value, name) => [
                  value == null ? "—" : ms(Number(value)),
                  String(name),
                ]}
              />
            }
          />
          <Line
            dataKey={percentile}
            stroke={`var(--color-${percentile})`}
            dot={loneDot(points, percentile, `var(--color-${percentile})`)}
            strokeWidth={1.75}
            isAnimationActive={false}
          />
          <Line
            dataKey="avg"
            stroke="var(--color-avg)"
            dot={loneDot(points, "avg", "var(--color-avg)")}
            strokeWidth={1.25}
            strokeOpacity={0.8}
            isAnimationActive={false}
          />
          {markers(deploys)}
        </LineChart>
      </ChartContainer>
      <Range data={data} />
    </div>
  )
}

export function Sparkline({
  data,
  className = "h-10 w-32",
  hoverKey,
}: {
  data: number[]
  className?: string
  hoverKey?: string
}) {
  const { hoveredKey, setHoveredKey } = useChartHover()
  const active = hoverKey != null && hoveredKey === hoverKey
  return (
    <ChartContainer config={config} className={className}>
      {/* recharts pads every side by 5px by default, which leaves a table
          cell's 10px-tall sparkline no plot area at all; the stroke's
          half-width is the only margin a chart this small needs. */}
      <AreaChart
        data={data.map((v) => ({ v }))}
        margin={{ top: 1, right: 1, bottom: 1, left: 1 }}
        onMouseEnter={hoverKey ? () => setHoveredKey(hoverKey) : undefined}
        onMouseLeave={hoverKey ? () => setHoveredKey(null) : undefined}
      >
        <Area
          dataKey="v"
          stroke={active ? "var(--primary)" : "var(--muted-foreground)"}
          fill={active ? "var(--primary)" : "var(--muted-foreground)"}
          fillOpacity={active ? 0.35 : 0.15}
          strokeWidth={active ? 2 : 1.25}
          isAnimationActive={false}
        />
      </AreaChart>
    </ChartContainer>
  )
}

function compact(n: number) {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(n >= 10_000 ? 0 : 1)}k`
  return String(n)
}
