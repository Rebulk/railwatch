import { Link, router, usePage } from "@inertiajs/react"

import { DurationPanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
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

// AR's transaction.active_record event reports outcome as commit, rollback,
// restart, or blank (still-open at instrumentation time).
function OutcomeBadge({ outcome }: { outcome: string }) {
  const variant =
    outcome === "rollback"
      ? "destructive"
      : outcome === "restart"
        ? "secondary"
        : outcome === "commit"
          ? "outline"
          : "secondary"
  return (
    <Badge variant={variant} className="font-mono">
      {outcome || "open"}
    </Badge>
  )
}

interface Recent {
  id: number
  outcome: string
  connection: string | null
  duration: number
  statement_count: number | null
  occurred_at: string
  execution_id: string | null
  execution_source: string | null
  execution_preview: string | null
  group_hash: string
}
interface Props {
  transactions: GroupRow[]
  series: SeriesPoint[]
  recent: Recent[]
  sort: string
  dir: string
}

export default function Transactions(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id

  const sortBy = (field: string) =>
    router.visit(
      R.applicationEnvironmentTransactionsPath(a, e, {
        window,
        sort: field,
        dir: p.sort === field && p.dir === "desc" ? "asc" : "desc",
      }),
      { preserveState: true },
    )

  return (
    <EnvLayout title="Transactions">
      <PageHeader
        title="Transactions"
        description="ActiveRecord transactions, grouped by connection and outcome."
        actions={<PercentilePicker />}
      />
      <DurationPanel label="Duration" data={p.series} percentile={percentile} />
      <DataTable
        rows={p.transactions}
        rowKey={(t) => t.group_hash}
        empty="No transactions in this window."
        columns={[
          {
            key: "name",
            header: "Connection · outcome",
            cell: (t) => <span className="font-mono text-xs">{t.name}</span>,
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (t) => <SparklineCell data={t.sparkline} />,
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
            cell: (t) => count(t.count),
          },
          {
            key: "errors",
            hideOnMobile: true,
            header: (
              <SortHeader
                label="Rollbacks"
                active={p.sort === "errors"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("errors")}
              />
            ),
            align: "right",
            cell: (t) => count(t.errors),
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
            cell: (t) => ms(t.avg, 2),
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
            cell: (t) => (
              <span className="font-semibold">{ms(t[percentile], 2)}</span>
            ),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent transactions</h2>
      <DataTable
        rows={p.recent}
        rowKey={(t) => t.id}
        columns={[
          {
            key: "when",
            header: "When",
            className: "w-40",
            cell: (t) => (
              <span className="text-xs tabular-nums">
                {when(t.occurred_at)}
              </span>
            ),
          },
          {
            key: "conn",
            hideOnMobile: true,
            header: "Connection",
            cell: (t) => (
              <span className="font-mono text-xs">{t.connection ?? ""}</span>
            ),
          },
          {
            key: "outcome",
            header: "Outcome",
            cell: (t) => <OutcomeBadge outcome={t.outcome} />,
          },
          {
            key: "statements",
            hideOnMobile: true,
            header: "Statements",
            align: "right",
            cell: (t) =>
              t.statement_count === null ? "—" : count(t.statement_count),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (t) =>
              t.execution_id ? (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={executionPath({
                    applicationId: a,
                    environmentId: e,
                    source: t.execution_source,
                    executionId: t.execution_id,
                  })!}
                >
                  {t.execution_preview}
                </Link>
              ) : (
                <span className="text-muted-foreground text-xs">–</span>
              ),
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (t) => ms(t.duration, 2),
          },
        ]}
      />
    </EnvLayout>
  )
}
