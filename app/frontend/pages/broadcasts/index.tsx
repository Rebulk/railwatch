import { Link, router, usePage } from "@inertiajs/react"
import { Cable } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { Badge } from "@/components/ui/badge"
import EnvLayout from "@/layouts/env-layout"
import { bytes, count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Stream {
  group_hash: string
  kind: string
  name: string
  count: number
  bytes: number
  avg: number
}
interface Recent {
  id: number
  kind: string
  failed: boolean
  stream: string | null
  channel: string | null
  action: string | null
  bytes: number | null
  duration: number
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
}
interface Props {
  streams: Stream[]
  recent: Recent[]
}

export default function Broadcasts(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const recentHref = (r: Recent) =>
    r.execution_id
      ? R.applicationEnvironmentRequestPath(a, e, r.execution_id)
      : null
  return (
    <EnvLayout title="Broadcasts">
      <PageHeader
        title="Broadcasts"
        description="Action Cable broadcasts, transmits, and channel actions (covers inertia_cable and Turbo Streams)."
      />
      <DataTable
        rows={p.streams}
        rowKey={(s) => `${s.group_hash}-${s.kind}`}
        empty={
          <EmptyState
            icon={Cable}
            title="No broadcasts in this window"
            description="Action Cable broadcasts appear here as your app sends them."
          />
        }
        columns={[
          { key: "k", header: "Kind", cell: (s) => s.kind },
          {
            key: "n",
            header: "Stream / channel",
            cell: (s) => <span className="font-mono text-xs">{s.name}</span>,
          },
          {
            key: "c",
            hideOnMobile: true,
            header: "Count",
            align: "right",
            cell: (s) => count(s.count),
          },
          {
            key: "b",
            hideOnMobile: true,
            header: "Bytes",
            align: "right",
            cell: (s) => bytes(s.bytes),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (s) => ms(s.avg, 3),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent</h2>
      <DataTable
        rows={p.recent}
        rowKey={(r) => r.id}
        empty={
          <EmptyState
            icon={Cable}
            title="No broadcasts in this window"
            description="Action Cable broadcasts appear here as your app sends them."
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
            key: "k",
            header: "Kind",
            cell: (r) =>
              r.failed ? (
                <span className="flex items-center gap-1.5">
                  {r.kind}
                  <Badge variant="destructive">failed</Badge>
                </span>
              ) : (
                r.kind
              ),
          },
          {
            key: "s",
            header: "Stream / channel",
            cell: (r) => (
              <span className="font-mono text-xs">
                {r.stream ?? r.channel}
                {r.action ? `#${r.action}` : ""}
              </span>
            ),
          },
          {
            key: "b",
            hideOnMobile: true,
            header: "Bytes",
            align: "right",
            cell: (r) => bytes(r.bytes),
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
