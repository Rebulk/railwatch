import { Link, router, usePage } from "@inertiajs/react"
import { BellRing } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Group {
  group_hash: string
  name: string
  count: number
  errors: number
  avg: number
  p95: number
}
interface Recent {
  id: number
  notifier: string | null
  delivery_method: string | null
  duration: number
  failed: boolean
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
}
interface Props {
  groups: Group[]
  recent: Recent[]
}

export default function Notifications(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const recentHref = (r: Recent) =>
    r.execution_id
      ? R.applicationEnvironmentRequestPath(a, e, r.execution_id)
      : null
  return (
    <EnvLayout title="Notifications">
      <PageHeader
        title="Notifications"
        description="ActionMailer/Noticed deliveries, grouped by notifier and delivery method."
      />
      <DataTable
        rows={p.groups}
        rowKey={(g) => g.group_hash}
        empty={
          <EmptyState
            icon={BellRing}
            title="No notifications in this window"
            description="Notifications delivered by your app appear here as they're sent."
          />
        }
        columns={[
          {
            key: "n",
            header: "Notifier",
            cell: (g) => <span className="font-mono text-xs">{g.name}</span>,
          },
          {
            key: "c",
            hideOnMobile: true,
            header: "Count",
            align: "right",
            cell: (g) => count(g.count),
          },
          {
            key: "f",
            hideOnMobile: true,
            header: "Failed",
            align: "right",
            cell: (g) => count(g.errors),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (g) => ms(g.avg, 3),
          },
          {
            key: "p95",
            header: "p95",
            align: "right",
            cell: (g) => ms(g.p95, 3),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent</h2>
      <DataTable
        rows={p.recent}
        rowKey={(r) => r.id}
        empty={
          <EmptyState
            icon={BellRing}
            title="No notifications in this window"
            description="Notifications delivered by your app appear here as they're sent."
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
            key: "n",
            header: "Notifier",
            cell: (r) => (
              <span className="font-mono text-xs">{r.notifier}</span>
            ),
          },
          {
            key: "dm",
            hideOnMobile: true,
            header: "Delivery method",
            cell: (r) => r.delivery_method,
          },
          {
            key: "f",
            hideOnMobile: true,
            header: "Failed",
            cell: (r) => (r.failed ? "yes" : ""),
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (r) => ms(r.duration, 3),
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
