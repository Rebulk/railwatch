import { AlertTriangle, Server } from "lucide-react"

import { ChartPanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { MetricChart } from "@/components/railwatch/metric-chart"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { UtilisationBar } from "@/components/railwatch/utilisation-bar"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { ago, bytes, count, ms, when } from "@/lib/format"

interface Sample {
  id: number
  server: string
  role: string | null
  pid: number | null
  deploy: string | null
  sampled_at: string
  threads_busy: number | null
  threads_max: number | null
  backlog: number | null
  pool_busy: number | null
  pool_size: number | null
  pool_waiting: number | null
  queue_depth: number | null
  queue_latency: number | null
  memory: number | null
}
interface HealthPoint {
  t: string
  utilisation: number
  backlog: number
  queue_depth: number
  queue_latency: number
}
interface QueueDepth {
  queue: string
  depth: number
}
interface Proc {
  id: number
  booted_at: string
  pid: number
  role: string
  server: string
  deploy: string | null
  ruby_version: string
  rails_version: string
  railwatch_version: string
  boot_seconds: number | null
  detail: Record<string, string>
}
interface Props {
  samples: Sample[]
  series: HealthPoint[]
  queues: QueueDepth[]
  silent_servers: string[]
  processes: Proc[]
}

const percent = (value: number) => `${value.toFixed(0)}%`

function sum(values: (number | null)[]) {
  return values.reduce<number>((n, v) => n + (v ?? 0), 0)
}

function max(values: (number | null)[]) {
  return values.reduce<number>((n, v) => Math.max(n, v ?? 0), 0)
}

export default function Processes(p: Props) {
  const utilisations = p.samples.flatMap((s) =>
    s.threads_max ? [((s.threads_busy ?? 0) / s.threads_max) * 100] : [],
  )
  const utilisation = utilisations.length
    ? utilisations.reduce((a, b) => a + b, 0) / utilisations.length
    : 0
  const backlog = sum(p.samples.map((s) => s.backlog))
  const queueDepth = max(p.samples.map((s) => s.queue_depth))
  const oldestJob = max(p.samples.map((s) => s.queue_latency))
  const reporting = p.samples.length > 0 || p.series.length > 0

  return (
    <EnvLayout title="Processes">
      <PageHeader
        title="Processes"
        description="What every web and worker process is doing right now: thread pools, socket backlog, queue depth, and the boots behind them."
      />
      {p.silent_servers.length > 0 && (
        <Card className="border-warning/40">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <AlertTriangle className="text-warning size-4" />
              {p.silent_servers.length === 1
                ? "1 expected host is silent"
                : `${p.silent_servers.length} expected hosts are silent`}
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            <div className="flex flex-wrap gap-1.5">
              {p.silent_servers.map((server) => (
                <span
                  key={server}
                  className="border-warning/40 bg-warning/10 text-warning rounded-sm border px-1.5 font-mono text-[11px]"
                >
                  {server}
                </span>
              ))}
            </div>
            <p className="text-muted-foreground text-xs">
              No health sample or execution from these hosts in the last 10
              minutes. Expected hosts come from your Kamal post-deploy hook, or
              from the environment settings if you set them by hand.
            </p>
          </CardContent>
        </Card>
      )}
      {reporting ? (
        <>
          <StatStrip>
            <Stat label="Live processes" value={p.samples.length} />
            <Stat
              label="Thread utilisation"
              value={percent(utilisation)}
              tone={
                utilisation >= 90
                  ? "destructive"
                  : utilisation >= 70
                    ? "warning"
                    : undefined
              }
              hint="averaged across live processes"
            />
            <Stat label="Backlog" value={count(backlog)} />
            <Stat label="Queue depth" value={count(queueDepth)} />
            <Stat label="Oldest job" value={ms(oldestJob)} />
          </StatStrip>
          <DataTable
            rows={p.samples}
            rowKey={(s) => s.id}
            empty={
              <EmptyState
                title="No process reported in the last 10 minutes"
                description="Health samples are older than the live window."
              />
            }
            columns={[
              {
                key: "server",
                header: "Server",
                cell: (s) => (
                  <span className="font-mono text-xs">{s.server}</span>
                ),
              },
              { key: "role", header: "Role", cell: (s) => s.role },
              {
                key: "pid",
                hideOnMobile: true,
                header: "PID",
                align: "right",
                cell: (s) => s.pid,
              },
              {
                key: "threads",
                header: "Threads",
                cell: (s) => (
                  <UtilisationBar busy={s.threads_busy} max={s.threads_max} />
                ),
              },
              {
                key: "pool",
                hideOnMobile: true,
                header: "DB pool",
                cell: (s) => (
                  <UtilisationBar busy={s.pool_busy} max={s.pool_size} />
                ),
              },
              {
                key: "mem",
                hideOnMobile: true,
                header: "Memory",
                align: "right",
                cell: (s) => bytes(s.memory),
              },
              {
                key: "seen",
                header: "Last sample",
                align: "right",
                cell: (s) => (
                  <span title={when(s.sampled_at)}>{ago(s.sampled_at)}</span>
                ),
              },
            ]}
          />
          {p.queues.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle>Queue depth</CardTitle>
              </CardHeader>
              <CardContent>
                <DataTable
                  rows={p.queues}
                  rowKey={(q) => q.queue}
                  columns={[
                    { key: "q", header: "Queue", cell: (q) => q.queue },
                    {
                      key: "d",
                      header: "Ready jobs",
                      align: "right",
                      cell: (q) => count(q.depth),
                    },
                  ]}
                />
              </CardContent>
            </Card>
          )}
          <div className="grid gap-4 lg:grid-cols-2">
            <ChartPanel label="Thread utilisation" value={percent(utilisation)}>
              <MetricChart
                label="Utilisation"
                format={percent}
                data={p.series.map((s) => ({ t: s.t, value: s.utilisation }))}
              />
            </ChartPanel>
            <ChartPanel label="Backlog" value={count(backlog)}>
              <MetricChart
                label="Backlog"
                color="var(--warning)"
                format={count}
                data={p.series.map((s) => ({ t: s.t, value: s.backlog }))}
              />
            </ChartPanel>
            <ChartPanel label="Queue depth" value={count(queueDepth)}>
              <MetricChart
                label="Ready jobs"
                format={count}
                data={p.series.map((s) => ({ t: s.t, value: s.queue_depth }))}
              />
            </ChartPanel>
            <ChartPanel label="Oldest job" value={ms(oldestJob)}>
              <MetricChart
                label="Oldest job"
                color="var(--danger)"
                format={(v) => ms(v)}
                data={p.series.map((s) => ({ t: s.t, value: s.queue_latency }))}
              />
            </ChartPanel>
          </div>
        </>
      ) : (
        <EmptyState
          icon={Server}
          title="No health samples yet"
          description="The gem reports thread pool, backlog and queue health every 15s from each web and worker process."
        />
      )}
      <h2 className="text-sm font-semibold">Process boots</h2>
      <DataTable
        rows={p.processes}
        rowKey={(x) => x.id}
        empty={
          <EmptyState
            icon={Server}
            title="No process has booted with Railwatch yet"
            description="Server processes report here once they boot with the gem installed."
          />
        }
        columns={[
          {
            key: "b",
            header: "Booted",
            cell: (x) => (
              <span className="text-xs" title={when(x.booted_at)}>
                {ago(x.booted_at)}
              </span>
            ),
          },
          {
            key: "s",
            header: "Server",
            cell: (x) => <span className="font-mono text-xs">{x.server}</span>,
          },
          { key: "r", header: "Role", cell: (x) => x.role },
          {
            key: "pid",
            hideOnMobile: true,
            header: "PID",
            align: "right",
            cell: (x) => x.pid,
          },
          {
            key: "d",
            header: "Deploy",
            cell: (x) => (
              <span className="font-mono text-xs">
                {x.deploy?.slice(0, 12)}
              </span>
            ),
          },
          {
            key: "v",
            hideOnMobile: true,
            header: "Ruby / Rails / Railwatch",
            cell: (x) => (
              <span className="font-mono text-xs">
                {x.ruby_version} / {x.rails_version} / {x.railwatch_version}
              </span>
            ),
          },
          {
            key: "ad",
            hideOnMobile: true,
            header: "DB / queue / cache",
            cell: (x) => (
              <span className="font-mono text-xs">
                {x.detail.database_adapter} / {x.detail.queue_adapter} /{" "}
                {x.detail.cache_store?.replace("ActiveSupport::Cache::", "")}
              </span>
            ),
          },
          {
            key: "boot",
            hideOnMobile: true,
            header: "Boot",
            align: "right",
            cell: (x) =>
              x.boot_seconds ? `${x.boot_seconds.toFixed(1)}s` : "–",
          },
        ]}
      />
    </EnvLayout>
  )
}
