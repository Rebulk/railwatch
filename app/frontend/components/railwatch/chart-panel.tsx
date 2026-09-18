import type { ReactNode } from "react"

import {
  LatencyChart,
  ThroughputChart,
} from "@/components/railwatch/series-chart"
import { count, ms } from "@/lib/format"
import { cn } from "@/lib/utils"
import type { DeployMarker, Percentile, SeriesPoint } from "@/types"

// Nightwatch's chart card: a mono label with the headline number at the
// left, a colour-keyed legend with per-series totals at the right, the
// chart below, and the bucket range under it (drawn by the chart itself).
export function ChartPanel({
  label,
  value,
  legend,
  children,
  className,
}: {
  label: string
  value: ReactNode
  legend?: { key: string; label: string; value: ReactNode; color: string }[]
  children: ReactNode
  className?: string
}) {
  return (
    <div className={cn("bg-card rounded-lg border p-4", className)}>
      <div className="mb-3 flex items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="label-caps">{label}</div>
          <div className="mt-0.5 text-xl font-semibold tracking-tight tabular-nums">
            {value}
          </div>
        </div>
        {legend && (
          <div className="flex shrink-0 gap-4">
            {legend.map((l) => (
              <div key={l.key} className="text-right">
                <div className="label-caps flex items-center justify-end gap-1.5">
                  <span
                    className="inline-block h-2.5 w-1 rounded-sm"
                    style={{ background: l.color }}
                  />
                  {l.label}
                </div>
                <div className="mt-0.5 font-mono text-sm tabular-nums">
                  {l.value}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
      {children}
    </div>
  )
}

function sum(data: SeriesPoint[], key: "count" | "errors" | "client_errors") {
  return data.reduce((n, d) => n + d[key], 0)
}

// What the three stacked series mean for each record type. Rollups store
// them as count / client_errors / errors; the words differ per page.
export const VOLUME_LEGENDS = {
  request: { ok: "1/2/3xx", warn: "4xx", error: "5xx" },
  job: { ok: "processed", warn: "released", error: "failed" },
  outcome: { ok: "ok", warn: null, error: "failed" },
  exception: { ok: "handled", warn: null, error: "unhandled" },
  cache: { ok: "hit", warn: "miss", error: "write" },
} as const

export type VolumeLegend = keyof typeof VOLUME_LEGENDS

// Volume panel: total as the headline, and a colour-keyed legend naming the
// ok / warning / error slices in the record type's own words.
export function VolumePanel({
  data,
  deploys,
  label = "Requests",
  seriesLabel,
  legend = "request",
  className,
}: {
  data: SeriesPoint[]
  deploys?: DeployMarker[]
  label?: string
  seriesLabel?: string
  legend?: VolumeLegend
  className?: string
}) {
  const total = sum(data, "count")
  const errors = sum(data, "errors")
  const client = sum(data, "client_errors")
  const words = VOLUME_LEGENDS[legend]
  const items = [
    {
      key: "ok",
      label: words.ok,
      value: count(total - errors - client),
      color: "var(--ok)",
    },
    words.warn && {
      key: "warn",
      label: words.warn,
      value: count(client),
      color: "var(--warning)",
    },
    {
      key: "error",
      label: words.error,
      value: count(errors),
      color: "var(--danger)",
    },
  ].filter((i): i is NonNullable<typeof i> => Boolean(i))
  return (
    <ChartPanel
      label={label}
      value={count(total)}
      className={className}
      legend={items}
    >
      <ThroughputChart data={data} deploys={deploys} label={seriesLabel} />
    </ChartPanel>
  )
}

// Duration panel: min — max range as the headline, avg and pNN legend.
export function DurationPanel({
  data,
  deploys,
  percentile = "p95",
  label = "Duration",
  className,
}: {
  data: SeriesPoint[]
  deploys?: DeployMarker[]
  percentile?: Percentile
  label?: string
  className?: string
}) {
  const withData = data.filter((d) => d.count > 0)
  const avgs = withData.map((d) => d.avg)
  const pcts = withData.map((d) => d[percentile])
  const avg = avgs.length ? avgs.reduce((a, b) => a + b, 0) / avgs.length : 0
  const pct = pcts.length ? Math.max(...pcts) : 0
  const lo = avgs.length ? Math.min(...avgs) : 0
  const hi = pcts.length ? Math.max(...pcts) : 0
  return (
    <ChartPanel
      label={label}
      value={withData.length ? `${ms(lo)} — ${ms(hi)}` : "—"}
      className={className}
      legend={[
        { key: "avg", label: "avg", value: ms(avg), color: "var(--warning)" },
        {
          key: percentile,
          label: percentile,
          value: ms(pct),
          color: "var(--primary)",
        },
      ]}
    >
      <LatencyChart data={data} deploys={deploys} percentile={percentile} />
    </ChartPanel>
  )
}
