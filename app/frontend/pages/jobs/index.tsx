import { Link, router, usePage } from "@inertiajs/react"
import { Workflow } from "lucide-react"

import { ChartHoverProvider } from "@/components/railwatch/chart-hover"
import { VolumePanel } from "@/components/railwatch/chart-panel"
import { CursorLoadMore } from "@/components/railwatch/cursor-load-more"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import {
  OriginIdentity,
  type OriginIdentityData,
} from "@/components/railwatch/origin-identity"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SavedViewsMenu } from "@/components/railwatch/saved-views"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { usePercentile } from "@/hooks/use-percentile"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, pct, when } from "@/lib/format"
import * as R from "@/routes"
import type {
  CursorMeta,
  DeployMarker,
  GroupRow,
  SeriesPoint,
  SharedProps,
} from "@/types"

interface JobRow extends OriginIdentityData {
  execution_id: string
  name: string
  outcome: string
  queue: string
  attempt: number
  duration: number
  queue_latency: number | null
  occurred_at: string
  exception_preview: string | null
}
interface Props {
  classes: GroupRow[]
  series: SeriesPoint[]
  queues: {
    queue: string
    count: number
    avg_latency: number
    failed: number
  }[]
  recent: JobRow[]
  pagination: CursorMeta
  deploys: DeployMarker[]
  q: string
}

export default function Jobs(p: Props) {
  const { environment, window, range } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id
  const timeParams =
    window === "custom"
      ? { from: range?.from, to: range?.to }
      : { window: window }
  const cursorTimeParams = range
    ? { from: range.from, to: range.to }
    : timeParams
  const recentPath = (cursor?: string) =>
    R.applicationEnvironmentJobsPath(a, e, {
      ...cursorTimeParams,
      q: p.q || undefined,
      cursor,
      limit: p.pagination.limit,
    })
  const jobHref = (j: JobRow) =>
    R.applicationEnvironmentJobPath(a, e, j.execution_id)
  const classHref = (x: GroupRow) =>
    R.klassApplicationEnvironmentJobsPath(a, e, x.group_hash, {
      ...timeParams,
      q: p.q || undefined,
    })
  return (
    <EnvLayout title="Jobs">
      <ChartHoverProvider>
        <PageHeader
          title="Jobs"
          description="Active Job attempts by class and queue, with queue latency and failures."
          actions={
            <>
              <SavedViewsMenu page="jobs" />
              <PercentilePicker />
            </>
          }
        />
        <VolumePanel
          legend="job"
          label="Job attempts"
          seriesLabel="Attempts"
          data={p.series}
          deploys={p.deploys}
        />
        <div className="grid gap-4 lg:grid-cols-3">
          <Card className="lg:col-span-1">
            <CardHeader>
              <CardTitle>Queues</CardTitle>
            </CardHeader>
            <CardContent>
              <DataTable
                rows={p.queues}
                rowKey={(q) => q.queue ?? "-"}
                columns={[
                  {
                    key: "q",
                    header: "Queue",
                    cell: (q) => (
                      <span className="font-mono text-xs">{q.queue}</span>
                    ),
                  },
                  {
                    key: "n",
                    header: "Attempts",
                    align: "right",
                    cell: (q) => count(q.count),
                  },
                  {
                    key: "lat",
                    hideOnMobile: true,
                    header: "Avg wait",
                    align: "right",
                    cell: (q) => ms(q.avg_latency),
                  },
                  {
                    key: "f",
                    header: "Failed",
                    align: "right",
                    cell: (q) => q.failed,
                  },
                ]}
              />
            </CardContent>
          </Card>
          <Card className="lg:col-span-2">
            <CardHeader>
              <CardTitle>Recent runs</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <FilterBar
                value={p.q}
                fields={[
                  { key: "after", label: "After" },
                  { key: "before", label: "Before" },
                  { key: "user", label: "User" },
                  { key: "tenant", label: "Tenant" },
                  { key: "deploy", label: "Deploy" },
                  {
                    key: "kind",
                    label: "Execution kind",
                    options: ["job"],
                  },
                  { key: "queue", label: "Queue" },
                  { key: "class", label: "Job class" },
                  { key: "job_id", label: "Job ID" },
                  {
                    key: "outcome",
                    label: "Outcome",
                    options: ["processed", "failed"],
                  },
                ]}
                onChange={(q) =>
                  router.visit(
                    R.applicationEnvironmentJobsPath(a, e, {
                      ...timeParams,
                      q: q || undefined,
                    }),
                    {
                      only: ["recent", "pagination", "q"],
                      preserveState: true,
                      reset: ["recent"],
                    },
                  )
                }
                placeholder="queue:default outcome:failed"
              />
              <DataTable
                rows={p.recent}
                rowKey={(j) => j.execution_id}
                empty={
                  <EmptyState
                    icon={Workflow}
                    title="No job runs in this window"
                    description="Job classes appear here once Active Job executions are reported."
                  />
                }
                onRowClick={(j) => router.visit(jobHref(j))}
                keyboardNav={{
                  onOpen: (j, opts) =>
                    opts?.newTab
                      ? globalThis.window.open(jobHref(j), "_blank")
                      : router.visit(jobHref(j)),
                }}
                columns={[
                  {
                    key: "when",
                    header: "When",
                    cell: (j) => (
                      <span className="text-xs">{when(j.occurred_at)}</span>
                    ),
                  },
                  {
                    key: "name",
                    header: "Job",
                    grow: true,
                    cell: (j) => (
                      <span className="font-mono text-xs">{j.name}</span>
                    ),
                  },
                  {
                    key: "st",
                    header: "Outcome",
                    cell: (j) => <StatusBadge outcome={j.outcome} />,
                  },
                  {
                    key: "att",
                    hideOnMobile: true,
                    header: "Attempt",
                    align: "right",
                    cell: (j) => j.attempt,
                  },
                  {
                    key: "user",
                    hideOnMobile: true,
                    header: "Origin user",
                    cell: (j) => (
                      <OriginIdentity
                        {...j}
                        applicationId={a}
                        environmentId={e}
                        kind="user"
                        range={range}
                        window={window}
                      />
                    ),
                  },
                  {
                    key: "tenant",
                    hideOnMobile: true,
                    header: "Origin tenant",
                    cell: (j) => (
                      <OriginIdentity
                        {...j}
                        applicationId={a}
                        environmentId={e}
                        kind="tenant"
                        range={range}
                        window={window}
                      />
                    ),
                  },
                  {
                    key: "ex",
                    hideOnMobile: true,
                    header: "Exception",
                    cell: (j) => (
                      <span className="text-destructive line-clamp-1 text-xs">
                        {j.exception_preview}
                      </span>
                    ),
                  },
                ]}
              />
              <CursorLoadMore
                meta={p.pagination}
                href={recentPath}
                only={["recent", "pagination"]}
              />
            </CardContent>
          </Card>
        </div>
        <DataTable
          rows={p.classes}
          rowKey={(x) => x.group_hash}
          empty={
            <EmptyState
              icon={Workflow}
              title="No job attempts in this window"
              description="Individual job executions appear here as they run."
            />
          }
          hoverKey={(x) => x.group_hash}
          keyboardNav={{
            onOpen: (x, opts) =>
              opts?.newTab
                ? globalThis.window.open(classHref(x), "_blank")
                : router.visit(classHref(x)),
          }}
          columns={[
            {
              key: "name",
              header: "Job",
              grow: true,
              cell: (x) => (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={classHref(x)}
                >
                  {x.name}
                </Link>
              ),
            },
            {
              key: "trend",
              hideOnMobile: true,
              header: "Trend",
              cell: (x) => (
                <SparklineCell data={x.sparkline} hoverKey={x.group_hash} />
              ),
            },
            {
              key: "n",
              header: "Attempts",
              align: "right",
              cell: (x) => count(x.count),
            },
            {
              key: "f",
              header: "Failed",
              align: "right",
              cell: (x) => (
                <span className={x.errors ? "text-destructive" : ""}>
                  {x.errors}
                </span>
              ),
            },
            {
              key: "fr",
              hideOnMobile: true,
              header: "Failure %",
              align: "right",
              cell: (x) => pct(x.errors, x.count),
            },
            {
              key: "avg",
              hideOnMobile: true,
              header: "Avg",
              align: "right",
              cell: (x) => ms(x.avg),
            },
            {
              key: percentile,
              header: percentile,
              align: "right",
              cell: (x) => (
                <span className="font-semibold">{ms(x[percentile])}</span>
              ),
            },
            {
              key: "max",
              hideOnMobile: true,
              header: "Max",
              align: "right",
              cell: (x) => ms(x.max),
            },
          ]}
        />
        <p className="text-muted-foreground text-xs">
          <StatusBadge outcome="processed" /> processed ·{" "}
          <StatusBadge outcome="failed" /> failed
        </p>
      </ChartHoverProvider>
    </EnvLayout>
  )
}
