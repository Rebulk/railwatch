import { router, usePage } from "@inertiajs/react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { FilterBar } from "@/components/railwatch/filter-bar"
import {
  OriginIdentity,
  type OriginIdentityData,
} from "@/components/railwatch/origin-identity"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { useWindow } from "@/hooks/use-window"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, pct, when } from "@/lib/format"
import * as R from "@/routes"
import type {
  DeployMarker,
  SeriesPoint,
  SharedProps,
  SummaryWithDelta,
} from "@/types"

interface Attempt extends OriginIdentityData {
  execution_id: string
  name: string
  outcome: string
  queue: string
  attempt: number
  duration: number
  queue_latency: number | null
  occurred_at: string
  exception_preview: string | null
  job_id: string
}
interface Props {
  name: string
  group_hash: string
  summary: SummaryWithDelta
  series: SeriesPoint[]
  attempts: Attempt[]
  deploys: DeployMarker[]
  q: string
}

export default function JobClass(p: Props) {
  const { environment, window, range } = usePage<SharedProps>().props
  const { window: currentWindow, label: windowLabel } = useWindow()
  const a = environment!.application_id
  const e = environment!.id
  const timeParams =
    window === "custom"
      ? { from: range?.from, to: range?.to }
      : { window: window }
  const s = p.summary.current
  const prev = p.summary.previous
  const deltaCaption =
    currentWindow === "custom"
      ? "vs previous period"
      : `vs previous ${windowLabel}`
  return (
    <EnvLayout
      title={p.name}
      crumbs={[
        {
          title: "Jobs",
          href: R.applicationEnvironmentJobsPath(a, e, { window }),
        },
        { title: p.name, href: "#" },
      ]}
    >
      <PageHeader title={<span className="font-mono">{p.name}</span>} />
      <StatStrip>
        <Stat label="Attempts" value={count(s.count)} />
        <Stat
          label="Failed"
          value={pct(s.errors, s.count)}
          tone={s.errors ? "destructive" : "success"}
          delta={{
            current: s.count ? (s.errors / s.count) * 100 : 0,
            previous: prev.count ? (prev.errors / prev.count) * 100 : 0,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="p50 / p95"
          value={ms(s.p50 / 1000)}
          hint={`p95 ${ms(s.p95 / 1000)}`}
          delta={{ current: s.p95, previous: prev.p95, goodDirection: "down" }}
          deltaCaption={deltaCaption}
        />
        <Stat label="Max" value={ms(s.max / 1000)} />
      </StatStrip>
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel
          legend="job"
          label="Attempts"
          seriesLabel="Attempts"
          data={p.series}
          deploys={p.deploys}
        />
        <DurationPanel label="Duration" data={p.series} deploys={p.deploys} />
      </div>
      <FilterBar
        value={p.q}
        fields={[
          { key: "user", label: "Origin user" },
          { key: "tenant", label: "Origin tenant" },
          { key: "queue", label: "Queue" },
          { key: "job_id", label: "Job ID" },
          {
            key: "outcome",
            label: "Outcome",
            options: ["processed", "failed"],
          },
        ]}
        onChange={(q) =>
          router.visit(
            R.klassApplicationEnvironmentJobsPath(a, e, p.group_hash, {
              ...timeParams,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="Filter attempts by origin, queue, or outcome"
      />
      <DataTable
        rows={p.attempts}
        rowKey={(x) => x.execution_id}
        onRowClick={(x) =>
          router.visit(R.applicationEnvironmentJobPath(a, e, x.execution_id))
        }
        columns={[
          {
            key: "when",
            header: "When",
            cell: (x) => <span className="text-xs">{when(x.occurred_at)}</span>,
          },
          {
            key: "st",
            header: "Outcome",
            cell: (x) => <StatusBadge outcome={x.outcome} />,
          },
          {
            key: "att",
            hideOnMobile: true,
            header: "Attempt",
            align: "right",
            cell: (x) => x.attempt,
          },
          {
            key: "q",
            hideOnMobile: true,
            header: "Queue",
            cell: (x) => x.queue,
          },
          {
            key: "user",
            hideOnMobile: true,
            header: "Origin user",
            cell: (x) => (
              <OriginIdentity
                {...x}
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
            cell: (x) => (
              <OriginIdentity
                {...x}
                applicationId={a}
                environmentId={e}
                kind="tenant"
                range={range}
                window={window}
              />
            ),
          },
          {
            key: "wait",
            hideOnMobile: true,
            header: "Waited",
            align: "right",
            cell: (x) => ms(x.queue_latency),
          },
          {
            key: "dur",
            header: "Duration",
            align: "right",
            cell: (x) => ms(x.duration),
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
