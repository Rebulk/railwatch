import { router, usePage } from "@inertiajs/react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { useWindow } from "@/hooks/use-window"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, pct, when } from "@/lib/format"
import * as R from "@/routes"
import type {
  DeployMarker,
  ExecutionRow,
  SeriesPoint,
  SharedProps,
  SummaryWithDelta,
} from "@/types"

interface Props {
  route: string
  group_hash: string
  summary: SummaryWithDelta
  series: SeriesPoint[]
  deploys: DeployMarker[]
  requests: ExecutionRow[]
}

export default function Route(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { window: currentWindow, label: windowLabel } = useWindow()
  const a = environment!.application_id
  const e = environment!.id
  const s = p.summary.current
  const prev = p.summary.previous
  const deltaCaption =
    currentWindow === "custom"
      ? "vs previous period"
      : `vs previous ${windowLabel}`
  return (
    <EnvLayout
      title={p.route}
      crumbs={[
        {
          title: "Requests",
          href: R.applicationEnvironmentRequestsPath(a, e, { window }),
        },
        { title: p.route, href: "#" },
      ]}
    >
      <PageHeader title={<span className="font-mono">{p.route}</span>} />
      <StatStrip>
        <Stat label="Requests" value={count(s.count)} />
        <Stat
          label="Errors"
          value={pct(s.errors, s.count)}
          tone={s.errors ? "destructive" : "success"}
          hint={`${s.errors} 5xx · ${s.client_errors} 4xx`}
          delta={{
            current: s.count ? (s.errors / s.count) * 100 : 0,
            previous: prev.count ? (prev.errors / prev.count) * 100 : 0,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat label="p50" value={ms(s.p50 / 1000)} />
        <Stat
          label="p95"
          value={ms(s.p95 / 1000)}
          delta={{ current: s.p95, previous: prev.p95, goodDirection: "down" }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="p99 / max"
          value={ms(s.p99 / 1000)}
          hint={`max ${ms(s.max / 1000)}`}
        />
      </StatStrip>
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel label="Requests" data={p.series} deploys={p.deploys} />
        <DurationPanel label="Latency" data={p.series} deploys={p.deploys} />
      </div>
      <DataTable
        rows={p.requests}
        rowKey={(x) => x.execution_id}
        onRowClick={(x) =>
          x.execution_id &&
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
            key: "q",
            hideOnMobile: true,
            header: "Queries",
            align: "right",
            cell: (x) => x.queries ?? "–",
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
            key: "tenant",
            hideOnMobile: true,
            header: "Tenant",
            cell: (x) => (
              <span className="font-mono text-xs">{x.tenant ?? "–"}</span>
            ),
          },
          {
            key: "comp",
            hideOnMobile: true,
            header: "Inertia",
            cell: (x) => (
              <span className="font-mono text-xs">
                {x.inertia_component ?? ""}
              </span>
            ),
          },
          {
            key: "ex",
            header: "Exception",
            cell: (x) => (
              <span className="text-destructive line-clamp-1 text-xs">
                {x.exception_preview ?? ""}
              </span>
            ),
          },
        ]}
      />
    </EnvLayout>
  )
}
