import { Head, Link, router } from "@inertiajs/react"
import { AlertOctagon, Plus } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { LiveDot } from "@/components/railwatch/live-dot"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import AppLayout from "@/layouts/app-layout"
import { ago, count } from "@/lib/format"
import * as R from "@/routes"

interface Env {
  id: number
  name: string
  last_seen_at: string | null
  paused: boolean
  open_issues: number
  events_this_month: number
  request_sparkline: number[]
  error_rate: number
}
interface App {
  id: number
  name: string
  slug: string
  issue_prefix: string
  environments: Env[]
}
interface Props {
  overview_apps: App[]
  recent_issues: {
    id: number
    key: string
    title: string
    kind: string
    last_seen_at: string
    occurrences: number
    application: string
    environment: string
  }[]
  usage: { events_this_month: number; quota: number; plan: string }
}

export default function Dashboard(p: Props) {
  return (
    <AppLayout breadcrumbs={[{ title: "Dashboard", href: R.dashboardPath() }]}>
      <Head title="Dashboard" />
      <div className="flex flex-1 flex-col gap-4 p-3 md:gap-5 md:px-6 md:pt-2 md:pb-6">
        <StatStrip>
          <Stat label="Applications" value={p.overview_apps.length} />
          <Stat
            label="Open issues"
            value={p.recent_issues.length}
            tone={p.recent_issues.length ? "destructive" : "success"}
          />
          <Stat
            label="Events this month"
            value={count(p.usage.events_this_month)}
            hint={`of ${count(p.usage.quota)} on ${p.usage.plan}`}
          />
        </StatStrip>
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {p.overview_apps.map((app) => (
            <Card key={app.id}>
              <CardHeader className="flex-row items-center justify-between">
                <div className="flex min-w-0 items-center gap-2">
                  <span className="bg-muted flex size-8 shrink-0 items-center justify-center rounded-md font-mono text-xs font-semibold">
                    {app.name.slice(0, 2).toUpperCase()}
                  </span>
                  <div className="min-w-0">
                    <Link
                      className="block truncate text-sm font-semibold hover:underline"
                      href={R.applicationPath(app.id)}
                    >
                      {app.name}
                    </Link>
                    <div className="label-caps">{app.issue_prefix}</div>
                  </div>
                </div>
                <Button
                  size="sm"
                  variant="outline"
                  className="h-7 text-xs"
                  onClick={() =>
                    router.visit(R.newApplicationEnvironmentPath(app.id))
                  }
                >
                  <Plus className="size-3" />
                  Environment
                </Button>
              </CardHeader>
              <CardContent className="space-y-2">
                {app.environments.map((env) => (
                  <Link
                    key={env.id}
                    href={R.applicationEnvironmentOverviewPath(app.id, env.id)}
                    className="hover:bg-muted flex items-center justify-between rounded-md border px-3 py-2 text-sm"
                  >
                    <span className="flex flex-1 items-center gap-2">
                      <LiveDot
                        lastSeenAt={env.paused ? null : env.last_seen_at}
                        thresholdMs={10 * 60 * 1000}
                      />
                      {env.name}
                    </span>
                    <SparklineCell data={env.request_sparkline} />
                    <span className="text-muted-foreground flex items-center gap-2 text-xs">
                      {env.error_rate > 0 && (
                        <Badge variant="destructive">
                          {(env.error_rate * 100).toFixed(1)}% err
                        </Badge>
                      )}
                      {env.open_issues > 0 && (
                        <Badge variant="destructive">{env.open_issues}</Badge>
                      )}
                      {env.last_seen_at ? ago(env.last_seen_at) : "no data"}
                    </span>
                  </Link>
                ))}
              </CardContent>
            </Card>
          ))}
          <Card className="border-dashed">
            <CardContent className="flex h-full items-center justify-center pt-6">
              <Button
                variant="outline"
                onClick={() => router.visit(R.newApplicationPath())}
              >
                Add application
              </Button>
            </CardContent>
          </Card>
        </div>
        <Card>
          <CardHeader>
            <CardTitle>Recent open issues</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.recent_issues}
              rowKey={(i) => i.id}
              empty={
                <EmptyState
                  icon={AlertOctagon}
                  title="No open issues"
                  description="Issues are opened when a request, job, or exception starts repeating."
                />
              }
              onRowClick={(i) => router.visit(R.issuePath(i.id))}
              columns={[
                {
                  key: "k",
                  header: "Issue",
                  cell: (i) => (
                    <span className="font-mono text-xs font-semibold">
                      {i.key}
                    </span>
                  ),
                },
                {
                  key: "t",
                  header: "Title",
                  cell: (i) => (
                    <span className="line-clamp-1 text-xs">{i.title}</span>
                  ),
                },
                {
                  key: "w",
                  hideOnMobile: true,
                  header: "Where",
                  cell: (i) => (
                    <span className="text-xs">
                      {i.application} · {i.environment}
                    </span>
                  ),
                },
                {
                  key: "n",
                  hideOnMobile: true,
                  header: "Events",
                  align: "right",
                  cell: (i) => count(i.occurrences),
                },
                {
                  key: "l",
                  header: "Last",
                  align: "right",
                  cell: (i) => ago(i.last_seen_at),
                },
              ]}
            />
          </CardContent>
        </Card>
      </div>
    </AppLayout>
  )
}
