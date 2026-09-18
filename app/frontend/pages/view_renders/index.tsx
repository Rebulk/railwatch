import { Link, router, usePage } from "@inertiajs/react"

import { DurationPanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SortHeader } from "@/components/railwatch/sort-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Badge } from "@/components/ui/badge"
import { usePercentile } from "@/hooks/use-percentile"
import EnvLayout from "@/layouts/env-layout"
import { executionPath } from "@/lib/execution-path"
import { count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { GroupRow, SeriesPoint, SharedProps } from "@/types"

function KindBadge({ kind }: { kind: string | null }) {
  if (!kind) return null
  const variant =
    kind === "partial" ? "secondary" : kind === "layout" ? "outline" : "default"
  return (
    <Badge variant={variant} className="font-mono">
      {kind}
    </Badge>
  )
}

type ViewRenderGroup = GroupRow & { kind: string | null }
interface Slowest {
  id: number
  identifier: string
  kind: string | null
  layout: string | null
  duration: number
  occurred_at: string
  execution_id: string | null
  execution_source: string | null
  execution_preview: string | null
  group_hash: string
}
interface Props {
  renders: ViewRenderGroup[]
  series: SeriesPoint[]
  slowest: Slowest[]
  sort: string
  dir: string
  q: string
}

export default function ViewRenders(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id

  const sortBy = (field: string) =>
    router.visit(
      R.applicationEnvironmentViewRendersPath(a, e, {
        window,
        sort: field,
        dir: p.sort === field && p.dir === "desc" ? "asc" : "desc",
        q: p.q || undefined,
      }),
      { preserveState: true },
    )

  return (
    <EnvLayout title="View renders">
      <PageHeader
        title="View renders"
        description="Every template your app rendered, grouped by identifier."
        actions={<PercentilePicker />}
      />
      <DurationPanel label="Duration" data={p.series} percentile={percentile} />
      <FilterBar
        value={p.q}
        fields={[{ key: "template", label: "Template" }]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentViewRendersPath(a, e, {
              window,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="template:widgets/_row"
      />
      <DataTable
        rows={p.renders}
        rowKey={(r) => r.group_hash}
        empty="No view renders in this window."
        columns={[
          {
            key: "id",
            header: "Template",
            grow: true,
            cell: (r) => <span className="font-mono text-xs">{r.name}</span>,
          },
          {
            key: "kind",
            hideOnMobile: true,
            header: "Kind",
            cell: (r) => <KindBadge kind={r.kind} />,
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (r) => <SparklineCell data={r.sparkline} />,
          },
          {
            key: "n",
            header: (
              <SortHeader
                label="Count"
                active={p.sort === "count"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("count")}
              />
            ),
            align: "right",
            cell: (r) => count(r.count),
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
            cell: (r) => ms(r.avg, 2),
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
            cell: (r) => (
              <span className="font-semibold">{ms(r[percentile], 2)}</span>
            ),
          },
          {
            key: "max",
            hideOnMobile: true,
            header: (
              <SortHeader
                label="Max"
                active={p.sort === "max"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("max")}
              />
            ),
            align: "right",
            cell: (r) => ms(r.max, 2),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Slowest recent renders</h2>
      <DataTable
        rows={p.slowest}
        rowKey={(s) => s.id}
        columns={[
          {
            key: "when",
            header: "When",
            className: "w-40",
            cell: (s) => (
              <span className="text-xs tabular-nums">
                {when(s.occurred_at)}
              </span>
            ),
          },
          {
            key: "id",
            header: "Template",
            grow: true,
            cell: (s) => (
              <span className="font-mono text-xs">{s.identifier}</span>
            ),
          },
          {
            key: "kind",
            hideOnMobile: true,
            header: "Kind",
            cell: (s) => <KindBadge kind={s.kind} />,
          },
          {
            key: "layout",
            hideOnMobile: true,
            header: "Layout",
            cell: (s) => (
              <span className="text-muted-foreground font-mono text-xs">
                {s.layout ?? ""}
              </span>
            ),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (s) =>
              s.execution_id ? (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={executionPath({
                    applicationId: a,
                    environmentId: e,
                    source: s.execution_source,
                    executionId: s.execution_id,
                  })!}
                >
                  {s.execution_preview}
                </Link>
              ) : (
                <span className="text-muted-foreground text-xs">–</span>
              ),
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (s) => ms(s.duration, 2),
          },
        ]}
      />
    </EnvLayout>
  )
}
