import { router, usePage } from "@inertiajs/react"
import { Terminal } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { StatusBadge } from "@/components/railwatch/status-badge"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { GroupRow, SharedProps } from "@/types"

interface Run {
  execution_id: string
  name: string
  exit_code: number | null
  duration: number
  occurred_at: string
  server: string | null
  exception_preview: string | null
}
interface Props {
  commands: GroupRow[]
  runs: Run[]
}

export default function Commands(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const runHref = (r: Run) =>
    R.applicationEnvironmentCommandPath(a, e, r.execution_id)
  return (
    <EnvLayout title="Commands">
      <PageHeader
        title="Commands"
        description="Rake tasks and rails runner executions."
      />
      <DataTable
        rows={p.commands}
        rowKey={(c) => c.group_hash}
        empty={
          <EmptyState
            icon={Terminal}
            title="No commands ran in this window"
            description="rails runner and console executions reported by the gem appear here."
          />
        }
        columns={[
          {
            key: "n",
            header: "Command",
            cell: (c) => <span className="font-mono text-xs">{c.name}</span>,
          },
          {
            key: "c",
            header: "Runs",
            align: "right",
            cell: (c) => count(c.count),
          },
          {
            key: "f",
            hideOnMobile: true,
            header: "Non-zero exit",
            align: "right",
            cell: (c) => c.errors,
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (c) => ms(c.avg),
          },
          {
            key: "max",
            hideOnMobile: true,
            header: "Max",
            align: "right",
            cell: (c) => ms(c.max),
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
            key: "n",
            header: "Command",
            cell: (r) => <span className="font-mono text-xs">{r.name}</span>,
          },
          {
            key: "x",
            hideOnMobile: true,
            header: "Exit",
            cell: (r) => (
              <StatusBadge
                label={String(r.exit_code ?? "?")}
                outcome={r.exit_code ? "failed" : "processed"}
              />
            ),
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (r) => ms(r.duration),
          },
          {
            key: "s",
            hideOnMobile: true,
            header: "Server",
            cell: (r) => <span className="font-mono text-xs">{r.server}</span>,
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
