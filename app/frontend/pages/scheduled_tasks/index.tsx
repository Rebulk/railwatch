import { Link, router, usePage } from "@inertiajs/react"
import { CalendarClock } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import {
  OriginIdentity,
  type OriginIdentityData,
} from "@/components/railwatch/origin-identity"
import { PageHeader } from "@/components/railwatch/page-header"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { Badge } from "@/components/ui/badge"
import EnvLayout from "@/layouts/env-layout"
import { ago, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Task {
  task_key: string
  runs: number
  failed: number
  avg: number
  last_run_at: string
  next_run_at: string | null
  schedule: string | null
}
interface Run extends OriginIdentityData {
  execution_id: string
  task_key: string
  name: string
  outcome: string
  duration: number
  occurred_at: string
  exception_preview: string | null
}
interface Props {
  tasks: Task[]
  runs: Run[]
  missed: { key: string; title: string; id: number }[]
}

export default function ScheduledTasks(p: Props) {
  const {
    environment,
    range,
    window: selectedWindow,
  } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const runHref = (r: Run) =>
    R.applicationEnvironmentScheduledTaskPath(a, e, r.execution_id)
  return (
    <EnvLayout title="Scheduled tasks">
      <PageHeader
        title="Scheduled tasks"
        description="Solid Queue recurring tasks from config/recurring.yml: runs, failures, and missed schedules."
      />
      {p.missed.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {p.missed.map((m) => (
            <Link key={m.id} href={R.issuePath(m.id)}>
              <Badge variant="destructive">
                {m.key} · {m.title}
              </Badge>
            </Link>
          ))}
        </div>
      )}
      <DataTable
        rows={p.tasks}
        rowKey={(t) => t.task_key}
        empty={
          <EmptyState
            icon={CalendarClock}
            title="No scheduled task has run in this window"
            description="Recurring and scheduled job runs appear here as they execute."
          />
        }
        columns={[
          {
            key: "k",
            header: "Task",
            cell: (t) => (
              <span className="font-mono text-xs">{t.task_key}</span>
            ),
          },
          {
            key: "s",
            header: "Schedule",
            cell: (t) => (
              <span className="text-muted-foreground font-mono text-xs">
                {t.schedule ?? "–"}
              </span>
            ),
          },
          {
            key: "next",
            hideOnMobile: true,
            header: "Next run",
            cell: (t) => (
              <span className="text-muted-foreground text-xs">
                {t.next_run_at ? <RelativeTime iso={t.next_run_at} /> : "–"}
              </span>
            ),
          },
          { key: "n", header: "Runs", align: "right", cell: (t) => t.runs },
          {
            key: "f",
            hideOnMobile: true,
            header: "Failed",
            align: "right",
            cell: (t) => (
              <span className={t.failed ? "text-destructive" : ""}>
                {t.failed}
              </span>
            ),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (t) => ms(t.avg),
          },
          {
            key: "last",
            header: "Last run",
            align: "right",
            cell: (t) => ago(t.last_run_at),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent runs</h2>
      <DataTable
        rows={p.runs}
        rowKey={(r) => r.execution_id}
        onRowClick={(r) => router.visit(runHref(r))}
        keyboardNav={{
          onOpen: (r, opts) =>
            opts?.newTab
              ? window.open(runHref(r), "_blank")
              : router.visit(runHref(r)),
        }}
        columns={[
          {
            key: "when",
            header: "When",
            cell: (r) => <span className="text-xs">{when(r.occurred_at)}</span>,
          },
          {
            key: "k",
            header: "Task",
            cell: (r) => (
              <span className="font-mono text-xs">{r.task_key}</span>
            ),
          },
          {
            key: "job",
            hideOnMobile: true,
            header: "Job",
            cell: (r) => <span className="font-mono text-xs">{r.name}</span>,
          },
          {
            key: "o",
            header: "Outcome",
            cell: (r) => <StatusBadge outcome={r.outcome} />,
          },
          {
            key: "user",
            hideOnMobile: true,
            header: "Origin user",
            cell: (r) => (
              <OriginIdentity
                {...r}
                applicationId={a}
                environmentId={e}
                kind="user"
                range={range}
                window={selectedWindow}
              />
            ),
          },
          {
            key: "tenant",
            hideOnMobile: true,
            header: "Origin tenant",
            cell: (r) => (
              <OriginIdentity
                {...r}
                applicationId={a}
                environmentId={e}
                kind="tenant"
                range={range}
                window={selectedWindow}
              />
            ),
          },
          {
            key: "d",
            hideOnMobile: true,
            header: "Duration",
            align: "right",
            cell: (r) => ms(r.duration),
          },
          {
            key: "ex",
            hideOnMobile: true,
            header: "Exception",
            cell: (r) => (
              <span className="text-destructive line-clamp-1 text-xs">
                {r.exception_preview ?? ""}
              </span>
            ),
          },
        ]}
      />
    </EnvLayout>
  )
}
