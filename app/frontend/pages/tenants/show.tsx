import { Link, router, usePage } from "@inertiajs/react"
import { useState } from "react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { PageHeader } from "@/components/railwatch/page-header"
import { Segmented, SegmentedItem } from "@/components/railwatch/segmented"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { useWindow } from "@/hooks/use-window"
import EnvLayout from "@/layouts/env-layout"
import { ago, count, ms, pct, when } from "@/lib/format"
import * as R from "@/routes"
import type { ExecutionRow, SeriesPoint, SharedProps } from "@/types"

interface TenantSummary {
  requests: number
  errors: number
  p95: number
  jobs: number
  failed_jobs: number
  exceptions: number
  users: number
  logs: number
}

interface RouteRow {
  group_hash: string
  name: string
  count: number
  errors: number
  avg: number
  max: number
}

interface JobRow {
  group_hash: string
  name: string
  count: number
  failed: number
  avg: number
  max: number
}

interface ExceptionRow {
  id: number
  class_name: string
  message: string
  occurred_at: string
  execution_id: string | null
  group_hash: string | null
  issue_id: number | null
  issue_key: string | null
}

interface PersonRow {
  ref: string
  name: string
  email: string | null
  last_seen_at: string | null
}

interface Props {
  tenant: string
  summary: { current: TenantSummary; previous: TenantSummary }
  series: SeriesPoint[]
  routes: RouteRow[]
  jobs: JobRow[]
  exceptions: ExceptionRow[]
  people: PersonRow[]
  recent_requests: ExecutionRow[]
  links: { logs: string; people: string }
}

type Tab = "routes" | "jobs" | "exceptions" | "people" | "requests"

export default function TenantShow(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { window: currentWindow, label: windowLabel } = useWindow()
  const [tab, setTab] = useState<Tab>("routes")
  const a = environment!.application_id
  const e = environment!.id
  const s = p.summary.current
  const previous = p.summary.previous
  const deltaCaption =
    currentWindow === "custom"
      ? "vs previous period"
      : `vs previous ${windowLabel}`

  const tabs: { key: Tab; label: string; badge: number }[] = [
    { key: "routes", label: "Routes", badge: p.routes.length },
    { key: "jobs", label: "Jobs", badge: p.jobs.length },
    { key: "exceptions", label: "Exceptions", badge: p.exceptions.length },
    { key: "people", label: "Users", badge: p.people.length },
    {
      key: "requests",
      label: "Recent requests",
      badge: p.recent_requests.length,
    },
  ]

  return (
    <EnvLayout
      title={p.tenant}
      crumbs={[
        {
          title: "Tenants",
          href: R.applicationEnvironmentTenantsPath(a, e, { window }),
        },
        { title: p.tenant, href: "#" },
      ]}
    >
      <PageHeader
        title={<span className="font-mono">{p.tenant}</span>}
        actions={
          <>
            <Link className="text-xs underline" href={p.links.logs}>
              Logs
            </Link>
            <Link className="text-xs underline" href={p.links.people}>
              Users
            </Link>
          </>
        }
      />
      <StatStrip>
        <Stat
          label="Requests"
          value={count(s.requests)}
          delta={{
            current: s.requests,
            previous: previous.requests,
            goodDirection: "up",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="5xx"
          value={pct(s.errors, s.requests)}
          tone={s.errors ? "destructive" : "success"}
          hint={`${s.errors} of ${s.requests}`}
          delta={{
            current: s.requests ? (s.errors / s.requests) * 100 : 0,
            previous: previous.requests
              ? (previous.errors / previous.requests) * 100
              : 0,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="p95"
          value={ms(s.p95)}
          delta={{
            current: s.p95,
            previous: previous.p95,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="Jobs"
          value={count(s.jobs)}
          hint={`${s.failed_jobs} failed`}
          tone={s.failed_jobs ? "destructive" : "default"}
        />
        <Stat
          label="Exceptions"
          value={count(s.exceptions)}
          delta={{
            current: s.exceptions,
            previous: previous.exceptions,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="Users"
          value={count(s.users)}
          hint={`${count(s.logs)} log lines`}
        />
      </StatStrip>
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel label="Requests" data={p.series} />
        <DurationPanel label="Latency" data={p.series} />
      </div>
      <div className="-mx-3 [scrollbar-width:none] overflow-x-auto px-3 md:mx-0 md:px-0 [&::-webkit-scrollbar]:hidden">
        <Segmented className="w-max">
          {tabs.map((t) => (
            <SegmentedItem
              key={t.key}
              mono={false}
              active={tab === t.key}
              onClick={() => setTab(t.key)}
              className="gap-1.5 px-3"
            >
              {t.label}
              <span className="opacity-60">{count(t.badge)}</span>
            </SegmentedItem>
          ))}
        </Segmented>
      </div>
      {tab === "routes" && (
        <DataTable
          rows={p.routes}
          rowKey={(x) => x.group_hash}
          empty="No requests from this tenant in this window."
          columns={[
            {
              key: "name",
              header: "Route",
              cell: (x) => (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={R.routeApplicationEnvironmentRequestsPath(
                    a,
                    e,
                    x.group_hash,
                    { window },
                  )}
                >
                  {x.name}
                </Link>
              ),
            },
            {
              key: "count",
              header: "Requests",
              align: "right",
              cell: (x) => count(x.count),
            },
            {
              key: "errors",
              header: "5xx",
              align: "right",
              cell: (x) => (
                <span className={x.errors ? "text-destructive" : ""}>
                  {count(x.errors)}
                </span>
              ),
            },
            {
              key: "avg",
              hideOnMobile: true,
              header: "Avg",
              align: "right",
              cell: (x) => ms(x.avg),
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
      )}
      {tab === "jobs" && (
        <DataTable
          rows={p.jobs}
          rowKey={(x) => x.group_hash}
          empty="No job attempts from this tenant in this window."
          columns={[
            {
              key: "name",
              header: "Job",
              cell: (x) => (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={R.klassApplicationEnvironmentJobsPath(
                    a,
                    e,
                    x.group_hash,
                    { window },
                  )}
                >
                  {x.name}
                </Link>
              ),
            },
            {
              key: "count",
              header: "Attempts",
              align: "right",
              cell: (x) => count(x.count),
            },
            {
              key: "failed",
              header: "Failed",
              align: "right",
              cell: (x) => (
                <span className={x.failed ? "text-destructive" : ""}>
                  {count(x.failed)}
                </span>
              ),
            },
            {
              key: "avg",
              hideOnMobile: true,
              header: "Avg",
              align: "right",
              cell: (x) => ms(x.avg),
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
      )}
      {tab === "exceptions" && (
        <DataTable
          rows={p.exceptions}
          rowKey={(x) => x.id}
          empty="No exceptions from this tenant in this window."
          columns={[
            {
              key: "when",
              header: "When",
              cell: (x) => (
                <span className="text-xs tabular-nums">
                  {when(x.occurred_at)}
                </span>
              ),
            },
            {
              key: "class",
              header: "Class",
              cell: (x) => (
                <span className="font-mono text-xs">{x.class_name}</span>
              ),
            },
            {
              key: "message",
              header: "Message",
              cell: (x) => (
                <span className="line-clamp-1 text-xs">{x.message}</span>
              ),
            },
            {
              key: "issue",
              header: "Issue",
              cell: (x) =>
                x.issue_id ? (
                  <Link
                    className="font-mono text-xs hover:underline"
                    href={R.issuePath(x.issue_id)}
                  >
                    {x.issue_key}
                  </Link>
                ) : (
                  <span className="text-muted-foreground text-xs">–</span>
                ),
            },
            {
              key: "exe",
              hideOnMobile: true,
              header: "Execution",
              cell: (x) =>
                x.execution_id ? (
                  <Link
                    className="font-mono text-xs hover:underline"
                    href={R.applicationEnvironmentRequestPath(
                      a,
                      e,
                      x.execution_id,
                    )}
                  >
                    {x.execution_id.slice(0, 8)}
                  </Link>
                ) : (
                  <span className="text-muted-foreground text-xs">–</span>
                ),
            },
          ]}
        />
      )}
      {tab === "people" && (
        <DataTable
          rows={p.people}
          rowKey={(x) => x.ref}
          empty="No users tagged with this tenant."
          onRowClick={(x) =>
            router.visit(R.applicationEnvironmentPersonPath(a, e, x.ref))
          }
          columns={[
            {
              key: "name",
              header: "User",
              cell: (x) => (
                <span className="text-xs">
                  <span className="font-medium">{x.name}</span>
                  {x.email && (
                    <span className="text-muted-foreground"> · {x.email}</span>
                  )}
                </span>
              ),
            },
            {
              key: "ref",
              hideOnMobile: true,
              header: "Ref",
              cell: (x) => <span className="font-mono text-xs">{x.ref}</span>,
            },
            {
              key: "seen",
              header: "Last seen",
              align: "right",
              cell: (x) => ago(x.last_seen_at),
            },
          ]}
        />
      )}
      {tab === "requests" && (
        <DataTable
          rows={p.recent_requests}
          rowKey={(x) => x.execution_id}
          empty="No requests from this tenant in this window."
          onRowClick={(x) =>
            router.visit(
              R.applicationEnvironmentRequestPath(a, e, x.execution_id),
            )
          }
          columns={[
            {
              key: "when",
              header: "When",
              cell: (x) => (
                <span className="text-xs tabular-nums">
                  {when(x.occurred_at)}
                </span>
              ),
            },
            {
              key: "name",
              header: "Route",
              cell: (x) => <span className="font-mono text-xs">{x.name}</span>,
            },
            {
              key: "status",
              header: "Status",
              cell: (x) => <StatusBadge status={x.status} />,
            },
            {
              key: "dur",
              header: "Duration",
              align: "right",
              cell: (x) => ms(x.duration),
            },
            {
              key: "user",
              hideOnMobile: true,
              header: "User",
              cell: (x) => (
                <span className="font-mono text-xs">{x.user_ref ?? "–"}</span>
              ),
            },
            {
              key: "ex",
              hideOnMobile: true,
              header: "Exception",
              cell: (x) => (
                <span className="text-destructive line-clamp-1 text-xs">
                  {x.exception_preview ?? ""}
                </span>
              ),
            },
          ]}
        />
      )}
    </EnvLayout>
  )
}
