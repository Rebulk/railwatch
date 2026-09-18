import { Link, router, usePage } from "@inertiajs/react"
import { HardDrive } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Op {
  service: string
  op: string
  count: number
  avg: number
  max: number
}
interface Recent {
  id: number
  service: string
  op: string
  key: string
  duration: number
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
}
interface Props {
  ops: Op[]
  recent: Recent[]
}

export default function StorageOps(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const recentHref = (r: Recent) =>
    r.execution_id
      ? R.applicationEnvironmentRequestPath(a, e, r.execution_id)
      : null
  return (
    <EnvLayout title="Storage">
      <PageHeader
        title="Storage"
        description="Active Storage service operations: uploads, downloads, deletes, URL generation, analysis, and transforms."
      />
      <DataTable
        rows={p.ops}
        rowKey={(o) => `${o.service}-${o.op}`}
        empty={
          <EmptyState
            icon={HardDrive}
            title="No storage operations in this window"
            description="Active Storage reads and writes instrumented by the gem appear here."
          />
        }
        columns={[
          { key: "s", header: "Service", cell: (o) => o.service },
          {
            key: "o",
            header: "Operation",
            cell: (o) => <span className="font-mono text-xs">{o.op}</span>,
          },
          {
            key: "n",
            header: "Count",
            align: "right",
            cell: (o) => count(o.count),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (o) => ms(o.avg),
          },
          {
            key: "max",
            hideOnMobile: true,
            header: "Max",
            align: "right",
            cell: (o) => ms(o.max),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent</h2>
      <DataTable
        rows={p.recent}
        rowKey={(r) => r.id}
        empty={
          <EmptyState
            icon={HardDrive}
            title="No storage operations in this window"
            description="Active Storage reads and writes instrumented by the gem appear here."
          />
        }
        keyboardNav={{
          onOpen: (r, opts) => {
            const href = recentHref(r)
            if (!href) return
            if (opts?.newTab) window.open(href, "_blank")
            else router.visit(href)
          },
        }}
        columns={[
          {
            key: "when",
            header: "When",
            cell: (r) => <span className="text-xs">{when(r.occurred_at)}</span>,
          },
          {
            key: "o",
            header: "Op",
            cell: (r) => (
              <span className="font-mono text-xs">
                {r.service} {r.op}
              </span>
            ),
          },
          {
            key: "k",
            hideOnMobile: true,
            header: "Key",
            cell: (r) => <span className="font-mono text-xs">{r.key}</span>,
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (r) => ms(r.duration),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (r) => {
              const href = recentHref(r)
              return href ? (
                <Link className="font-mono text-xs hover:underline" href={href}>
                  {r.execution_preview}
                </Link>
              ) : null
            },
          },
        ]}
      />
    </EnvLayout>
  )
}
