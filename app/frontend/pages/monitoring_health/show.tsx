import type { ReactNode } from "react"

import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import EnvLayout from "@/layouts/env-layout"
import { ago, bytes, count, when } from "@/lib/format"

type Status = "ok" | "warning" | "critical" | "unknown" | "not_applicable"
interface Check {
  status: Status
  message?: string
}
interface Freshness extends Check {
  at?: string | null
  age_seconds?: number | null
}
interface Snapshot {
  checked_at: string
  host: "embedded" | "cloud"
  status: Status
  attention: { key: string; severity: Status; title: string; detail: string }[]
  freshness: Check & {
    ingest?: Freshness
    health?: Freshness
    paused?: boolean
  }
  capture: Check & {
    from?: string
    covered_from?: string | null
    batches?: number
    limited?: boolean
    accepted?: number | null
    rejected?: number | null
    dropped_by_client?: number | null
    max_backpressure_factor?: number | null
  }
  storage: Check & {
    adapter?: string
    data_bytes?: number | null
    wal_bytes?: number | null
    physical_bytes?: number | null
    allocated_bytes?: number
    active_bytes?: number
    freelist_bytes?: number
    auto_vacuum?: string
    journal_mode?: string
    budget?: Check & { bytes: number | null; percent: number | null }
  }
  retention: Check & {
    days?: number
    cutoff?: string
    probes?: (Check & {
      table: string
      oldest_at?: string | null
      expired?: boolean
      behind?: boolean
    })[]
  }
  followups: Check & {
    pending?: number
    limited?: boolean
    oldest_at?: string | null
  }
  maintenance: Check & {
    tasks?: {
      name: string
      status: Status
      state: string
      last_run_at?: string | null
      next_due_at?: string | null
      lease_expires_at?: string | null
    }[]
  }
  writer: Check & { mode?: string }
  export: Check & {
    enabled?: boolean
    destination_state?: string
    queued_bytes?: number
    queued_deliveries?: number
    oldest_at?: string | null
    retry_at?: string | null
    latest_enqueued_at?: string | null
    latest_state?: string | null
    latest_disposition?: string | null
    counters?: Record<string, number>
    limits?: { bytes: number; deliveries: number; age_seconds: number }
  }
}

const labels: Record<Status, string> = {
  ok: "OK",
  warning: "Needs attention",
  critical: "Needs action",
  unknown: "Unknown",
  not_applicable: "Not applicable",
}

function StatusBadge({ status }: { status: Status }) {
  return (
    <Badge
      variant={
        status === "critical"
          ? "destructive"
          : status === "ok"
            ? "secondary"
            : "outline"
      }
    >
      {labels[status]}
    </Badge>
  )
}

const size = (value: number | null | undefined) =>
  value == null ? "Unknown" : value === 0 ? "0 B" : bytes(value)
const number = (value: number | null | undefined) =>
  value == null ? "Unknown" : count(value)
const recorded = (value: string | null | undefined) =>
  value ? when(value) : "Not recorded"

function Facts({ children }: { children: ReactNode }) {
  return (
    <dl className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-x-6 gap-y-3 text-sm">
      {children}
    </dl>
  )
}

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="text-right tabular-nums">{children}</dd>
    </>
  )
}

function HealthCard({
  title,
  check,
  children,
}: {
  title: string
  check: Check
  children?: ReactNode
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardAction>
          <StatusBadge status={check.status} />
        </CardAction>
        <CardDescription>{check.message}</CardDescription>
      </CardHeader>
      {children && <CardContent>{children}</CardContent>}
    </Card>
  )
}

export default function MonitoringHealth({
  monitoring_health: health,
}: {
  monitoring_health: Snapshot
}) {
  const {
    freshness,
    capture,
    storage,
    retention,
    followups,
    maintenance,
    writer,
  } = health
  const exporting = health.export

  return (
    <EnvLayout title="Monitoring health">
      <div className="flex flex-col gap-5">
        <PageHeader
          title="Monitoring health"
          description={`Railwatch ${health.host === "embedded" ? "embedded" : "Cloud"} pipeline · checked ${when(health.checked_at)}`}
          withWindow={false}
          actions={<StatusBadge status={health.status} />}
        />
        <StatStrip>
          <Stat
            label="Last ingest"
            value={freshness.ingest?.at ? ago(freshness.ingest.at) : "Unknown"}
            hint={
              freshness.paused ? "Environment paused" : "Newest committed batch"
            }
          />
          <Stat
            label="Reported client drops"
            value={number(capture.dropped_by_client)}
            hint={
              capture.limited
                ? "Partial sample · last hour"
                : "Recorded batches · last hour"
            }
          />
          <Stat
            label="Peak backpressure"
            value={
              capture.max_backpressure_factor == null
                ? "Unknown"
                : `${capture.max_backpressure_factor}×`
            }
            hint="1× uses the configured sample rate"
          />
          <Stat
            label="Telemetry disk use"
            value={size(storage.physical_bytes)}
            hint="Data file + WAL"
          />
        </StatStrip>
        {health.attention.map((item) => (
          <Alert
            key={item.key}
            variant={item.severity === "critical" ? "destructive" : "default"}
          >
            <AlertTitle>{item.title}</AlertTitle>
            <AlertDescription>{item.detail}</AlertDescription>
          </Alert>
        ))}
        <div className="grid items-start gap-5 xl:grid-cols-2">
          <HealthCard title="Freshness" check={freshness}>
            <div className="flex flex-col gap-4">
              {(
                [
                  ["Ingest", freshness.ingest],
                  ["Process health", freshness.health],
                ] as const
              ).map(
                ([label, check]) =>
                  check && (
                    <div key={label} className="flex flex-col gap-1 text-sm">
                      <div className="flex items-center justify-between gap-3">
                        <span>{label}</span>
                        <StatusBadge status={check.status} />
                      </div>
                      <p>{recorded(check.at)}</p>
                      <p className="text-muted-foreground">{check.message}</p>
                    </div>
                  ),
              )}
            </div>
          </HealthCard>
          <HealthCard title="Capture and backpressure" check={capture}>
            <div className="flex flex-col gap-4">
              <Facts>
                <Fact label="Batches inspected">
                  {number(capture.batches)}
                  {capture.limited ? " (partial)" : ""}
                </Fact>
                <Fact label="Oldest batch inspected">
                  {recorded(capture.covered_from)}
                </Fact>
                <Fact label="Accepted records">{number(capture.accepted)}</Fact>
                <Fact label="Rejected records">{number(capture.rejected)}</Fact>
                <Fact label="Reported client drops">
                  {number(capture.dropped_by_client)}
                </Fact>
              </Facts>
              <p className="text-muted-foreground text-sm">
                {capture.limited
                  ? "The most recent 1,000 batches are shown. Totals are lower bounds for the last hour."
                  : "Checks cover recorded batches from the last hour, independently of the dashboard time window."}
              </p>
            </div>
          </HealthCard>
          <HealthCard title="SQLite storage" check={storage}>
            {storage.adapter === "SQLite" && (
              <div className="flex flex-col gap-4">
                <Facts>
                  <Fact label="Data file">{size(storage.data_bytes)}</Fact>
                  <Fact label="WAL file">{size(storage.wal_bytes)}</Fact>
                  <Fact label="Allocated database pages">
                    {size(storage.allocated_bytes)}
                  </Fact>
                  <Fact label="Reusable free pages">
                    {size(storage.freelist_bytes)}
                  </Fact>
                  <Fact label="Pages in use">{size(storage.active_bytes)}</Fact>
                  <Fact label="Journal / auto vacuum">
                    {storage.journal_mode} / {storage.auto_vacuum}
                  </Fact>
                </Facts>
                {storage.budget && (
                  <div className="flex flex-col gap-2 text-sm">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span>
                        Storage budget
                        {storage.budget.bytes
                          ? ` · ${size(storage.budget.bytes)}`
                          : ""}
                      </span>
                      <StatusBadge status={storage.budget.status} />
                    </div>
                    <p className="text-muted-foreground">
                      {storage.budget.message}
                    </p>
                  </div>
                )}
              </div>
            )}
          </HealthCard>
          <HealthCard title="Retention" check={retention}>
            {retention.probes && (
              <div className="flex flex-col gap-4">
                <Facts>
                  <Fact label="Raw telemetry retention">
                    {retention.days} days
                  </Fact>
                  <Fact label="Current cutoff">
                    {recorded(retention.cutoff)}
                  </Fact>
                </Facts>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Table</TableHead>
                      <TableHead>Oldest row</TableHead>
                      <TableHead>Expired rows</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {retention.probes.map((probe) => (
                      <TableRow key={probe.table}>
                        <TableCell>{probe.table}</TableCell>
                        <TableCell>
                          {probe.status === "unknown"
                            ? "Unknown"
                            : recorded(probe.oldest_at)}
                        </TableCell>
                        <TableCell>
                          {probe.status === "unknown"
                            ? "Unknown"
                            : probe.behind
                              ? "Prune is behind"
                              : probe.expired
                                ? "Awaiting daily prune"
                                : "None found"}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </HealthCard>
          <HealthCard title="Ingest follow-ups" check={followups}>
            {followups.pending != null && (
              <Facts>
                <Fact label="Pending follow-ups">
                  {followups.limited ? "At least " : ""}
                  {number(followups.pending)}
                </Fact>
                <Fact label="Oldest pending">
                  {followups.oldest_at ? recorded(followups.oldest_at) : "None"}
                </Fact>
              </Facts>
            )}
          </HealthCard>
          <HealthCard title="Writer" check={writer} />
        </div>
        <HealthCard title="Maintenance" check={maintenance}>
          {maintenance.tasks && (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Task</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead>Last success</TableHead>
                  <TableHead>Next due</TableHead>
                  <TableHead>Lease expires</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {maintenance.tasks.map((task) => (
                  <TableRow key={task.name}>
                    <TableCell>{task.name.replace(/_/g, " ")}</TableCell>
                    <TableCell>{task.state}</TableCell>
                    <TableCell>{recorded(task.last_run_at)}</TableCell>
                    <TableCell>
                      {task.next_due_at
                        ? recorded(task.next_due_at)
                        : "Unknown"}
                    </TableCell>
                    <TableCell>
                      {task.lease_expires_at
                        ? recorded(task.lease_expires_at)
                        : "None"}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </HealthCard>
        <HealthCard title="Export" check={exporting}>
          {exporting.destination_state && (
            <div className="grid gap-6 lg:grid-cols-2">
              <Facts>
                <Fact label="Destination state">
                  {exporting.destination_state}
                </Fact>
                <Fact label="Queued deliveries">
                  {number(exporting.queued_deliveries)}
                </Fact>
                <Fact label="Queued payload bytes">
                  {size(exporting.queued_bytes)}
                </Fact>
                <Fact label="Oldest queued delivery">
                  {exporting.oldest_at ? recorded(exporting.oldest_at) : "None"}
                </Fact>
                <Fact label="Retry after">
                  {exporting.retry_at
                    ? recorded(exporting.retry_at)
                    : "No delay recorded"}
                </Fact>
                <Fact label="Latest enqueued delivery">
                  {recorded(exporting.latest_enqueued_at)}
                </Fact>
                <Fact label="Latest delivery state">
                  {exporting.latest_disposition ??
                    exporting.latest_state ??
                    "Not recorded"}
                </Fact>
              </Facts>
              <div className="flex flex-col gap-4">
                <Facts>
                  {Object.entries(exporting.counters ?? {}).map(
                    ([name, value]) => (
                      <Fact
                        key={name}
                        label={`${name} ${name === "shed" ? "records" : "deliveries"} (lifetime)`}
                      >
                        {number(value)}
                      </Fact>
                    ),
                  )}
                </Facts>
                {exporting.limits && (
                  <p className="text-muted-foreground text-sm">
                    Queue limits: {size(exporting.limits.bytes)},{" "}
                    {count(exporting.limits.deliveries)} deliveries,{" "}
                    {Math.round(exporting.limits.age_seconds / 3600)} hours. The
                    storage budget covers the whole telemetry file separately.
                  </p>
                )}
              </div>
            </div>
          )}
        </HealthCard>
      </div>
    </EnvLayout>
  )
}
