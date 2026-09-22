import { Link, usePage } from "@inertiajs/react"
import { AlertOctagon, Server } from "lucide-react"

import { ChartHoverProvider } from "@/components/railwatch/chart-hover"
import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { Onboarding } from "@/components/railwatch/onboarding"
import { PageHeader } from "@/components/railwatch/page-header"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { IssueStatusBadge } from "@/components/railwatch/status-badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useWindow } from "@/hooks/use-window"
import EnvLayout from "@/layouts/env-layout"
import { ago, count, ms, pct } from "@/lib/format"
import {
  type Attention,
  NeedsAttention,
} from "@/pages/overview/needs-attention"
import { crashFreeTone, rate } from "@/pages/releases/release-health"
import * as R from "@/routes"
import type {
  DeployMarker,
  GroupRow,
  IssueRow,
  SeriesPoint,
  SharedProps,
  SummaryWithDelta,
} from "@/types"

interface Props {
  attention: Attention
  totals: { requests: SummaryWithDelta; jobs: SummaryWithDelta }
  request_series: SeriesPoint[]
  job_series: SeriesPoint[]
  slow_routes: GroupRow[]
  top_jobs: GroupRow[]
  issues: IssueRow[]
  deploys: DeployMarker[]
  // null until the environment reports sessions at all.
  release_health: {
    deploy: string
    ref: string
    sessions: number
    crash_free_sessions: number
  } | null
  processes: Record<
    string,
    {
      role: string
      deploy: string
      ruby_version: string
      rails_version: string
      railwatch_version: string
      booted_at: string
    }
  >
}

export default function Overview(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const { window: currentWindow, label: windowLabel } = useWindow()
  const a = environment!.application_id
  const e = environment!.id
  const r = p.totals.requests.current
  const rPrev = p.totals.requests.previous
  const j = p.totals.jobs.current
  const jPrev = p.totals.jobs.previous
  const deltaCaption =
    currentWindow === "custom"
      ? "vs previous period"
      : `vs previous ${windowLabel}`
  return (
    <EnvLayout title="Overview" crumbs={[{ title: "Overview", href: "#" }]}>
      <ChartHoverProvider>
        <PageHeader
          title={`${environment!.application_name} · ${environment!.name}`}
          description={
            environment!.last_seen_at ? (
              <>
                Last event <RelativeTime iso={environment!.last_seen_at} />
              </>
            ) : (
              "No events received yet."
            )
          }
        />
        {!environment!.last_seen_at && (
          <Onboarding tokenPrefix={environment!.token_prefix} />
        )}
        <StatStrip>
          <Stat
            label="Requests"
            roll={{ value: r.count, format: count }}
            hint={`${pct(r.errors, r.count)} 5xx · ${pct(r.client_errors, r.count)} 4xx`}
            tone={r.errors > 0 ? "warning" : undefined}
            delta={{
              current: r.count,
              previous: rPrev.count,
              goodDirection: "up",
            }}
            deltaCaption={deltaCaption}
          />
          <Stat
            label="Request p95"
            value={ms(r.p95 / 1000)}
            hint={`avg ${ms(r.avg / 1000)} · max ${ms(r.max / 1000)}`}
            delta={{
              current: r.p95,
              previous: rPrev.p95,
              goodDirection: "down",
            }}
            deltaCaption={deltaCaption}
          />
          <Stat
            label="Job attempts"
            roll={{ value: j.count, format: count }}
            hint={`${pct(j.errors, j.count)} failed`}
            tone={j.errors > 0 ? "warning" : undefined}
            delta={{
              current: j.count,
              previous: jPrev.count,
              goodDirection: "up",
            }}
            deltaCaption={deltaCaption}
          />
          <Stat
            label="Open issues"
            value={p.attention.open_issue_count}
            hint="Across all time"
            tone={p.attention.open_issue_count ? "destructive" : undefined}
          />
          {p.release_health && (
            <Stat
              label="Crash-free sessions"
              value={rate(p.release_health.crash_free_sessions)}
              tone={crashFreeTone(p.release_health.crash_free_sessions)}
              hint={`${p.release_health.ref} · ${count(p.release_health.sessions)} sessions`}
            />
          )}
        </StatStrip>
        <NeedsAttention
          attention={p.attention}
          applicationId={a}
          environmentId={e}
        />
        <div className="grid gap-4 lg:grid-cols-2">
          <VolumePanel
            label="Requests"
            data={p.request_series}
            deploys={p.deploys}
          />
          <DurationPanel
            label="Request latency"
            data={p.request_series}
            deploys={p.deploys}
          />
        </div>
        <div className="grid gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Slowest routes (p95)</CardTitle>
            </CardHeader>
            <CardContent>
              <DataTable
                rows={p.slow_routes}
                rowKey={(x) => x.group_hash}
                hoverKey={(x) => x.group_hash}
                columns={[
                  {
                    key: "name",
                    header: "Route",
                    grow: true,
                    cell: (x) => (
                      <Link
                        className="font-mono text-xs hover:underline"
                        href={R.routeApplicationEnvironmentRequestsPath(
                          a,
                          e,
                          x.group_hash,
                        )}
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
                      <SparklineCell
                        data={x.sparkline}
                        hoverKey={x.group_hash}
                      />
                    ),
                  },
                  {
                    key: "count",
                    header: "Count",
                    align: "right",
                    cell: (x) => count(x.count),
                  },
                  {
                    key: "p95",
                    header: "p95",
                    align: "right",
                    cell: (x) => ms(x.p95),
                  },
                  {
                    key: "errors",
                    hideOnMobile: true,
                    header: "5xx",
                    align: "right",
                    cell: (x) => x.errors,
                  },
                ]}
              />
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle>Recent open issues · all time</CardTitle>
            </CardHeader>
            <CardContent>
              <DataTable
                rows={p.issues}
                rowKey={(x) => x.id}
                empty={
                  <EmptyState
                    icon={AlertOctagon}
                    title="No open issues"
                    description="Issues are grouped from repeated request, job, and exception errors."
                  />
                }
                columns={[
                  {
                    key: "key",
                    header: "Issue",
                    cell: (x) => (
                      <Link
                        className="font-mono text-xs hover:underline"
                        href={R.issuePath(x.id)}
                      >
                        {x.key}
                      </Link>
                    ),
                  },
                  {
                    key: "title",
                    header: "Title",
                    cell: (x) => (
                      <span className="line-clamp-1 text-xs">{x.title}</span>
                    ),
                  },
                  {
                    key: "status",
                    hideOnMobile: true,
                    header: "",
                    cell: (x) => <IssueStatusBadge status={x.status} />,
                  },
                  {
                    key: "n",
                    hideOnMobile: true,
                    header: "Lifetime count",
                    align: "right",
                    cell: (x) => (
                      <span
                        title={
                          x.kind === "exception"
                            ? "Recorded occurrences"
                            : "Breached evaluation windows"
                        }
                      >
                        {count(x.occurrences)}
                      </span>
                    ),
                  },
                  {
                    key: "last",
                    header: "Last",
                    align: "right",
                    cell: (x) => ago(x.last_seen_at),
                  },
                ]}
              />
            </CardContent>
          </Card>
        </div>
        <div className="grid gap-4 lg:grid-cols-2">
          <VolumePanel
            label="Jobs"
            legend="job"
            seriesLabel="Attempts"
            data={p.job_series}
            deploys={p.deploys}
          />
          <Card>
            <CardHeader>
              <CardTitle>Servers</CardTitle>
            </CardHeader>
            <CardContent>
              <DataTable
                rows={Object.entries(p.processes)}
                rowKey={([s]) => s}
                empty={
                  <EmptyState
                    icon={Server}
                    title="No process has reported yet"
                    description="Server processes report here once they boot with the gem installed."
                  />
                }
                columns={[
                  {
                    key: "server",
                    header: "Server",
                    cell: ([s]) => (
                      <span className="font-mono text-xs">{s}</span>
                    ),
                  },
                  { key: "role", header: "Role", cell: ([, v]) => v.role },
                  {
                    key: "deploy",
                    header: "Deploy",
                    cell: ([, v]) => (
                      <span className="font-mono text-xs">
                        {v.deploy?.slice(0, 10)}
                      </span>
                    ),
                  },
                  {
                    key: "ver",
                    hideOnMobile: true,
                    header: "Ruby / Rails",
                    cell: ([, v]) => `${v.ruby_version} / ${v.rails_version}`,
                  },
                  {
                    key: "boot",
                    hideOnMobile: true,
                    header: "Booted",
                    align: "right",
                    cell: ([, v]) => ago(v.booted_at),
                  },
                ]}
              />
            </CardContent>
          </Card>
        </div>
      </ChartHoverProvider>
    </EnvLayout>
  )
}
