import { router, usePage } from "@inertiajs/react"
import { MonitorSmartphone } from "lucide-react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SortHeader } from "@/components/railwatch/sort-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { usePercentile } from "@/hooks/use-percentile"
import EnvLayout from "@/layouts/env-layout"
import { bytes, count, ms, pct, when } from "@/lib/format"
import * as R from "@/routes"
import type { GroupRow, SeriesPoint, SharedProps } from "@/types"

interface Visit {
  id: number
  component: string
  url: string
  method: string
  duration: number
  status: string
  partial: boolean
  only: string[]
  props_bytes: number | null
  occurred_at: string
  user_ref: string | null
  lcp: number | null
  cls: number | null
  inp: number | null
  ttfb: number | null
}
type VitalKey = "lcp" | "cls" | "inp" | "ttfb"
interface Vital {
  value: number
  rating: "good" | "needs-improvement" | "poor"
  samples: number
}
interface Props {
  components: (GroupRow & { lcp: number | null; inp: number | null })[]
  series: SeriesPoint[]
  recent: Visit[]
  vitals: Partial<Record<VitalKey, Vital>>
  sort: string
  dir: string
  q: string
}

const vitalKeys: VitalKey[] = ["lcp", "cls", "inp", "ttfb"]
const vitalLabels: Record<VitalKey, string> = {
  lcp: "LCP",
  cls: "CLS",
  inp: "INP",
  ttfb: "TTFB",
}
const ratingTones = {
  good: "success",
  "needs-improvement": "warning",
  poor: "destructive",
} as const

// cls is a unitless layout-shift score; the rest are durations.
const vitalValue = (key: VitalKey, value: number) =>
  key === "cls" ? value.toFixed(2) : ms(value)

const visitVitals = (v: Visit) =>
  [
    v.lcp === null ? null : `LCP ${ms(v.lcp)}`,
    v.inp === null ? null : `INP ${ms(v.inp)}`,
    v.cls === null ? null : `CLS ${v.cls.toFixed(2)}`,
  ]
    .filter((part): part is string => part !== null)
    .join(" · ")

export default function Visits(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id

  const sortBy = (field: string) =>
    router.visit(
      R.applicationEnvironmentVisitsPath(a, e, {
        window,
        sort: field,
        dir: p.sort === field && p.dir === "desc" ? "asc" : "desc",
      }),
      { preserveState: true },
    )

  const measured = vitalKeys.filter((key) => p.vitals[key])

  return (
    <EnvLayout title="Visits">
      <PageHeader
        title="Inertia visits"
        description="Page-load timing measured in the browser: from router start to finish, per component, with prop payload size."
        actions={<PercentilePicker />}
      />
      {measured.length > 0 ? (
        <StatStrip>
          {measured.map((key) => {
            const vital = p.vitals[key]!
            return (
              <Stat
                key={key}
                label={vitalLabels[key]}
                value={vitalValue(key, vital.value)}
                tone={ratingTones[vital.rating]}
                hint={`${vital.rating} · p75 of ${count(vital.samples)}`}
              />
            )
          })}
        </StatStrip>
      ) : (
        <p className="text-muted-foreground text-xs">
          Web vitals are reported by the browser client from the initial page
          load; update app/frontend/lib/railwatch.ts from{" "}
          <span className="font-mono">
            bin/rails generate railwatch:install
          </span>
          .
        </p>
      )}
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel
          legend="outcome"
          label="Visits"
          seriesLabel="Visits"
          data={p.series}
        />
        <DurationPanel
          label="Duration"
          data={p.series}
          percentile={percentile}
        />
      </div>
      <DataTable
        rows={p.components}
        rowKey={(c) => c.group_hash}
        empty={
          <EmptyState
            icon={MonitorSmartphone}
            title="No visits yet"
            description="Call startRailwatch() from your Inertia entrypoint to track page visits."
          />
        }
        columns={[
          {
            key: "c",
            header: "Component",
            cell: (c) => <span className="font-mono text-xs">{c.name}</span>,
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (c) => <SparklineCell data={c.sparkline} />,
          },
          {
            key: "n",
            header: (
              <SortHeader
                label="Visits"
                active={p.sort === "count"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("count")}
              />
            ),
            align: "right",
            cell: (c) => count(c.count),
          },
          {
            key: "e",
            hideOnMobile: true,
            header: "Errors",
            align: "right",
            cell: (c) => pct(c.errors, c.count),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: (
              <SortHeader
                label="Avg"
                active={p.sort === "avg"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("avg")}
              />
            ),
            align: "right",
            cell: (c) => ms(c.avg),
          },
          {
            key: "lcp",
            hideOnMobile: true,
            header: "LCP",
            align: "right",
            cell: (c) => ms(c.lcp),
          },
          {
            key: "inp",
            hideOnMobile: true,
            header: "INP",
            align: "right",
            cell: (c) => ms(c.inp),
          },
          {
            key: percentile,
            header: (
              <SortHeader
                label={percentile}
                active={p.sort === percentile}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy(percentile)}
              />
            ),
            align: "right",
            cell: (c) => (
              <span className="font-semibold">{ms(c[percentile])}</span>
            ),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent</h2>
      <FilterBar
        value={p.q}
        fields={[{ key: "component", label: "Component" }]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentVisitsPath(a, e, {
              window,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="component:Widgets/Show"
      />
      <DataTable
        rows={p.recent}
        rowKey={(v) => v.id}
        columns={[
          {
            key: "when",
            header: "When",
            cell: (v) => <span className="text-xs">{when(v.occurred_at)}</span>,
          },
          {
            key: "st",
            header: "",
            cell: (v) => (
              <StatusBadge
                label={v.status}
                outcome={
                  v.status === "error"
                    ? "failed"
                    : v.status === "success"
                      ? "processed"
                      : undefined
                }
              />
            ),
          },
          {
            key: "c",
            header: "Component",
            cell: (v) => (
              <span className="font-mono text-xs">
                {v.component}
                {v.partial && (
                  <span className="text-muted-foreground">
                    {" "}
                    (partial: {v.only.join(", ")})
                  </span>
                )}
              </span>
            ),
          },
          {
            key: "u",
            hideOnMobile: true,
            header: "URL",
            cell: (v) => (
              <span className="font-mono text-xs">
                {v.method.toUpperCase()} {v.url}
              </span>
            ),
          },
          {
            key: "v",
            hideOnMobile: true,
            header: "Vitals",
            cell: (v) => (
              <span className="text-muted-foreground font-mono text-[11px] tabular-nums">
                {visitVitals(v)}
              </span>
            ),
          },
          {
            key: "b",
            hideOnMobile: true,
            header: "Props",
            align: "right",
            cell: (v) => bytes(v.props_bytes),
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (v) => ms(v.duration),
          },
        ]}
      />
    </EnvLayout>
  )
}
