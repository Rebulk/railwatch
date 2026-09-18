import { DataTable } from "@/components/railwatch/data-table"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Progress } from "@/components/ui/progress"
import EnvLayout from "@/layouts/env-layout"
import { bytes, count } from "@/lib/format"

interface Props {
  account: {
    plan: string
    monthly_event_quota: number
    additional_events_cap: number
    retention_days: number
    events_this_month: number
  }
  environment_events: number
  by_type: [string, number][]
  by_day: { day: string; count: number }[]
  dropped_by_client: number
  backpressure_batches: number
  backpressure_peak: number
  rejected: number
  recent_rejections: { type: string; reason: string }[]
  payloads: { name: string; rows: number; bytes: number | null }[]
  db_bytes: number | null
}

export default function Usage(p: Props) {
  const used = p.account.events_this_month
  const quota = p.account.monthly_event_quota + p.account.additional_events_cap
  return (
    <EnvLayout title="Usage">
      <PageHeader
        withWindow={false}
        title="Usage"
        description={`Plan ${p.account.plan} · ${count(p.account.monthly_event_quota)} events per month · ${p.account.retention_days}-day retention`}
      />
      <Card>
        <CardContent className="space-y-2 pt-4">
          <div className="flex justify-between text-sm">
            <span>Account events this month</span>
            <span className="tabular-nums">
              {count(used)} / {count(quota)}
            </span>
          </div>
          <Progress value={Math.min(100, (used / Math.max(1, quota)) * 100)} />
          <p className="text-muted-foreground text-xs">
            Ingest pauses at the quota. Raise it in account settings or lower
            RAILWATCH_REQUEST_SAMPLE_RATE in the app.
          </p>
        </CardContent>
      </Card>
      <StatStrip>
        <Stat
          label="This environment"
          value={count(p.environment_events)}
          hint="events this month"
        />
        <Stat
          label="Dropped by client"
          value={count(p.dropped_by_client)}
          hint="buffer overflow in the app (30d)"
          tone={p.dropped_by_client ? "warning" : undefined}
        />
        <Stat
          label="Under backpressure"
          value={count(p.backpressure_batches)}
          hint={`batches sampled down in the app (30d), peak ${p.backpressure_peak}x; raise RAILWATCH_BUFFER_SIZE / RAILWATCH_BUFFER_BYTES or lower sample rates`}
          tone={p.backpressure_batches > 0 ? "warning" : undefined}
        />
        <Stat
          label="Rejected"
          value={count(p.rejected)}
          hint="malformed records (30d)"
          tone={p.rejected ? "warning" : undefined}
        />
        <Stat
          label="Telemetry DB"
          value={bytes(p.db_bytes)}
          hint="SQLite file on disk"
        />
      </StatStrip>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>By record type (30d)</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.by_type}
              rowKey={([t]) => t}
              columns={[
                {
                  key: "t",
                  header: "Type",
                  cell: ([t]) => <span className="font-mono text-xs">{t}</span>,
                },
                {
                  key: "n",
                  header: "Events",
                  align: "right",
                  cell: ([, n]) => count(n),
                },
              ]}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>By day (30d)</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.by_day}
              rowKey={(d) => d.day}
              columns={[
                { key: "d", header: "Day", cell: (d) => d.day },
                {
                  key: "n",
                  header: "Events",
                  align: "right",
                  cell: (d) => count(d.count),
                },
              ]}
            />
          </CardContent>
        </Card>
      </div>
      <Card>
        <CardHeader>
          <CardTitle>Stored payloads</CardTitle>
        </CardHeader>
        <CardContent>
          <p className="text-muted-foreground mb-2 text-xs">
            Profiles and attachments are the only records that store a blob.
            Sizes are the uncompressed bytes the app sent; both are pruned with
            everything else at {p.account.retention_days} days.
          </p>
          <DataTable
            rows={p.payloads}
            rowKey={(r) => r.name}
            columns={[
              { key: "n", header: "Record", cell: (r) => r.name },
              {
                key: "rows",
                header: "Rows",
                align: "right",
                cell: (r) => count(r.rows),
              },
              {
                key: "b",
                header: "Size",
                align: "right",
                cell: (r) => bytes(r.bytes),
              },
            ]}
          />
        </CardContent>
      </Card>
      {p.recent_rejections.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Recent rejections</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.recent_rejections}
              rowKey={(r) => `${r.type}-${r.reason}`}
              columns={[
                {
                  key: "t",
                  header: "Type",
                  cell: (r) => (
                    <span className="font-mono text-xs">{r.type}</span>
                  ),
                },
                {
                  key: "r",
                  header: "Reason",
                  cell: (r) => (
                    <span className="font-mono text-xs">{r.reason}</span>
                  ),
                },
              ]}
            />
          </CardContent>
        </Card>
      )}
    </EnvLayout>
  )
}
