import { Area, AreaChart, CartesianGrid, XAxis, YAxis } from "recharts"

import {
  type ChartConfig,
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from "@/components/ui/chart"

export interface MetricPoint {
  t: string
  value: number
}

const axisTick = { fontSize: 10, fontFamily: "var(--font-mono)" }

function tick(t: string) {
  return new Date(t).toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
  })
}

function stamp(t: string) {
  return new Date(t).toLocaleString(undefined, {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  })
}

// One plain {t, value} metric over time — health samples rather than
// rollups, so there is no ok/4xx/5xx vocabulary to stack. Same axes,
// gridlines and bucket-range caption as series-chart.tsx.
export function MetricChart({
  label,
  data,
  format,
  color = "var(--primary)",
  className = "h-32",
}: {
  label: string
  data: MetricPoint[]
  format: (value: number) => string
  color?: string
  className?: string
}) {
  const config = { value: { label, color } } satisfies ChartConfig
  return (
    <div>
      <ChartContainer config={config} className={`${className} w-full`}>
        <AreaChart data={data}>
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
            tickFormatter={(v) => format(Number(v))}
          />
          <ChartTooltip
            content={
              <ChartTooltipContent
                labelFormatter={(v) => stamp(String(v))}
                formatter={(value) => [format(Number(value)), label]}
              />
            }
          />
          <Area
            dataKey="value"
            stroke="var(--color-value)"
            fill="var(--color-value)"
            fillOpacity={0.15}
            strokeWidth={1.75}
            isAnimationActive={false}
          />
        </AreaChart>
      </ChartContainer>
      {data.length > 0 && (
        <div className="text-muted-foreground mt-1 flex justify-between font-mono text-[10px]">
          <span>{stamp(data[0].t)}</span>
          <span>{stamp(data[data.length - 1].t)}</span>
        </div>
      )}
    </div>
  )
}
