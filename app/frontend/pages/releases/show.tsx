import { Link, usePage } from "@inertiajs/react"
import { AlertOctagon, MonitorSmartphone } from "lucide-react"

import { ChartPanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { SessionStatusChart } from "@/components/railwatch/series-chart"
import { IssueStatusBadge } from "@/components/railwatch/status-badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { ago, count, ms, when } from "@/lib/format"
import { ReleaseHealthStrip } from "@/pages/releases/release-health"
import * as R from "@/routes"
import type {
  ReleaseHealthSummary,
  SessionStatusPoint,
  SharedProps,
} from "@/types"

interface SessionRow {
  id: number
  session_id: string
  source: string | null
  status: string | null
  user_ref: string | null
  duration: number | null
  requests: number
  visits: number
  errors: number
  occurred_at: string
  started_at: string | null
}

interface IssueLink {
  id: number
  key: string
  title: string
  status: string
}

interface Props {
  release: {
    deploy: string
    ref: string
    name: string | null
    deploy_id: number | null
    deployed_at: string | null
    previous_ref: string | null
  }
  summary: ReleaseHealthSummary
  previous_summary: ReleaseHealthSummary | null
  series: SessionStatusPoint[]
  sessions: SessionRow[]
  new_issues: IssueLink[]
  resolved_issues: IssueLink[]
}

function IssueTable({
  rows,
  empty,
}: {
  rows: IssueLink[]
  empty: { title: string; description: string }
}) {
  return (
    <DataTable
      rows={rows}
      rowKey={(i) => i.id}
      empty={<EmptyState icon={AlertOctagon} {...empty} />}
      columns={[
        {
          key: "k",
          header: "Issue",
          cell: (i) => (
            <Link
              className="font-mono text-xs hover:underline"
              href={R.issuePath(i.id)}
            >
              {i.key}
            </Link>
          ),
        },
        {
          key: "t",
          header: "Title",
          cell: (i) => <span className="line-clamp-1 text-xs">{i.title}</span>,
        },
        {
          key: "s",
          header: "",
          cell: (i) => <IssueStatusBadge status={i.status} />,
        },
      ]}
    />
  )
}

export default function ReleaseShow(p: Props) {
  const { environment, window: w } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  return (
    <EnvLayout
      title={p.release.ref}
      crumbs={[
        {
          title: "Releases",
          href: R.applicationEnvironmentReleasesPath(a, e, { window: w }),
        },
        { title: p.release.ref, href: "#" },
      ]}
    >
      <PageHeader
        withWindow={false}
        title={<span className="font-mono">{p.release.deploy}</span>}
        description={`${p.release.deployed_at ? when(p.release.deployed_at) : "never deployed"}${p.release.name ? ` · ${p.release.name}` : ""}${p.release.previous_ref ? ` · after ${p.release.previous_ref}` : ""}`}
        actions={
          p.release.deploy_id && (
            <Button asChild variant="outline" size="sm">
              <Link
                href={R.applicationEnvironmentDeployPath(
                  a,
                  e,
                  p.release.deploy_id,
                )}
              >
                Deploy
              </Link>
            </Button>
          )
        }
      />
      <ReleaseHealthStrip
        health={p.summary}
        previous={p.previous_summary}
        deltaCaption={
          p.release.previous_ref ? `vs ${p.release.previous_ref}` : undefined
        }
      />
      <ChartPanel label="Sessions by status" value={count(p.summary.sessions)}>
        <SessionStatusChart data={p.series} />
      </ChartPanel>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Issues first seen in this release</CardTitle>
          </CardHeader>
          <CardContent>
            <IssueTable
              rows={p.new_issues}
              empty={{
                title: "No new issues in this release",
                description:
                  "Issues first seen while this release was live would show here.",
              }}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Issues resolved in this release</CardTitle>
          </CardHeader>
          <CardContent>
            <IssueTable
              rows={p.resolved_issues}
              empty={{
                title: "No issues marked resolved in this release",
                description:
                  "Issues resolved and tagged with this deploy would show here.",
              }}
            />
          </CardContent>
        </Card>
      </div>
      <h2 className="text-sm font-semibold">Sessions</h2>
      <DataTable
        rows={p.sessions}
        rowKey={(s) => s.id}
        rowClassName={(s) =>
          s.status === "crashed" ? "bg-destructive/5" : undefined
        }
        empty={
          <EmptyState
            icon={MonitorSmartphone}
            title="No sessions reported for this release"
            description="Sessions come from the browser client and the gem's request middleware; config.track_sessions turns both off."
          />
        }
        columns={[
          {
            key: "id",
            header: "Session",
            cell: (s) => (
              <span className="font-mono text-xs">{s.session_id}</span>
            ),
          },
          {
            key: "source",
            hideOnMobile: true,
            header: "Source",
            cell: (s) => <span className="text-xs">{s.source}</span>,
          },
          {
            key: "status",
            header: "Status",
            cell: (s) => (
              <span
                className={
                  s.status === "crashed"
                    ? "text-destructive text-xs font-semibold"
                    : "text-xs"
                }
              >
                {s.status}
              </span>
            ),
          },
          {
            key: "user",
            hideOnMobile: true,
            header: "User",
            cell: (s) => (
              <span className="font-mono text-xs">{s.user_ref}</span>
            ),
          },
          {
            key: "duration",
            header: "Duration",
            align: "right",
            cell: (s) => ms(s.duration),
          },
          {
            key: "activity",
            hideOnMobile: true,
            header: "Requests / visits",
            align: "right",
            cell: (s) => `${count(s.requests)} / ${count(s.visits)}`,
          },
          {
            key: "errors",
            hideOnMobile: true,
            header: "Errors",
            align: "right",
            cell: (s) => (
              <span className={s.errors ? "text-destructive" : ""}>
                {count(s.errors)}
              </span>
            ),
          },
          {
            key: "started",
            header: "Started",
            align: "right",
            cell: (s) => ago(s.started_at),
          },
        ]}
      />
    </EnvLayout>
  )
}
