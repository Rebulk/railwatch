import { Link, router, usePage } from "@inertiajs/react"
import {
  ArrowUpRight,
  Check,
  ChevronDown,
  ChevronRight,
  Copy,
} from "lucide-react"
import { useState } from "react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { useClipboard } from "@/hooks/use-clipboard"
import { usePercentile } from "@/hooks/use-percentile"
import EnvLayout from "@/layouts/env-layout"
import { bytes, count, ms, pct, when } from "@/lib/format"
import * as R from "@/routes"
import type { GroupRow, SeriesPoint, SharedProps } from "@/types"

interface Recent {
  id: number
  host: string
  method: string
  url: string
  status_code: number | null
  duration: number
  request_size: number | null
  response_size: number | null
  error: string | null
  source: string | null
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
  response_body: string | null
}
interface Props {
  hosts: GroupRow[]
  series: SeriesPoint[]
  recent: Recent[]
  q: string
}

// The gem captures a response body only for failed calls, and only the
// first 4 KiB of it, so the whole thing already sits in the row -- tapping
// just grows the row rather than fetching anything.
function ResponseBody({ body }: { body: string }) {
  const [open, setOpen] = useState(false)
  const [, copy] = useClipboard()
  const [copied, setCopied] = useState(false)
  const Chevron = open ? ChevronDown : ChevronRight
  return (
    <div className="flex flex-col items-end gap-1">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1"
      >
        <Chevron className="size-3" />
        Body
      </button>
      {open && (
        <div className="w-[70vw] max-w-[36rem] space-y-1 text-left">
          <button
            type="button"
            onClick={() => {
              void (async () => {
                const ok = await copy(body)
                if (ok) {
                  setCopied(true)
                  setTimeout(() => setCopied(false), 1200)
                }
              })()
            }}
            className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1"
          >
            {copied ? (
              <Check className="size-3" />
            ) : (
              <Copy className="size-3" />
            )}
            Copy
          </button>
          <pre className="bg-muted max-h-64 overflow-auto rounded p-2 font-mono text-[10px] break-all whitespace-pre-wrap">
            {body}
          </pre>
        </div>
      )}
    </div>
  )
}

export default function OutgoingRequests(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id
  const recentHref = (r: Recent) =>
    r.execution_id
      ? R.applicationEnvironmentRequestPath(a, e, r.execution_id)
      : null
  return (
    <EnvLayout title="Outgoing requests">
      <PageHeader
        title="Outgoing requests"
        description="HTTP calls your app makes to other services, by host and method."
        actions={<PercentilePicker />}
      />
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel
          legend="request"
          label="Outgoing requests"
          seriesLabel="Calls"
          data={p.series}
        />
        <DurationPanel
          label="Latency"
          data={p.series}
          percentile={percentile}
        />
      </div>
      <DataTable
        rows={p.hosts}
        rowKey={(h) => h.group_hash}
        empty={
          <EmptyState
            icon={ArrowUpRight}
            title="No outgoing requests in this window"
            description="HTTP calls your app makes to other services appear here."
          />
        }
        columns={[
          {
            key: "h",
            header: "Host",
            cell: (h) => <span className="font-mono text-xs">{h.name}</span>,
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (h) => <SparklineCell data={h.sparkline} />,
          },
          {
            key: "n",
            header: "Calls",
            align: "right",
            cell: (h) => count(h.count),
          },
          {
            key: "f",
            hideOnMobile: true,
            header: "Failed",
            align: "right",
            cell: (h) => (
              <span className={h.errors ? "text-destructive" : ""}>
                {pct(h.errors, h.count)}
              </span>
            ),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (h) => ms(h.avg),
          },
          {
            key: percentile,
            header: percentile,
            align: "right",
            cell: (h) => (
              <span className="font-semibold">{ms(h[percentile])}</span>
            ),
          },
          {
            key: "max",
            hideOnMobile: true,
            header: "Max",
            align: "right",
            cell: (h) => ms(h.max),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent</h2>
      <FilterBar
        value={p.q}
        fields={[
          { key: "host", label: "Host" },
          {
            key: "status",
            label: "Status",
            options: ["2xx", "3xx", "4xx", "5xx"],
          },
        ]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentOutgoingRequestsPath(a, e, {
              window,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="host:api.test status:5xx"
      />
      <DataTable
        rows={p.recent}
        rowKey={(r) => r.id}
        empty={
          <EmptyState
            icon={ArrowUpRight}
            title="No outgoing requests in this window"
            description="HTTP calls your app makes to other services appear here."
          />
        }
        keyboardNav={{
          onOpen: (r, opts) => {
            const href = recentHref(r)
            if (!href) return
            if (opts?.newTab) globalThis.window.open(href, "_blank")
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
            key: "st",
            header: "Status",
            cell: (r) => (
              <StatusBadge
                status={r.status_code}
                label={r.error ? "error" : undefined}
                outcome={r.error ? "failed" : undefined}
              />
            ),
          },
          {
            key: "u",
            hideOnMobile: true,
            header: "Request",
            cell: (r) => (
              <span className="font-mono text-xs">
                <span className="font-semibold">{r.method}</span> {r.url}
              </span>
            ),
          },
          {
            key: "sz",
            hideOnMobile: true,
            header: "In/out",
            align: "right",
            cell: (r) => `${bytes(r.request_size)} / ${bytes(r.response_size)}`,
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (r) => ms(r.duration),
          },
          {
            key: "src",
            hideOnMobile: true,
            header: "Source",
            cell: (r) => (
              <span className="text-muted-foreground font-mono text-xs">
                {r.source ?? ""}
              </span>
            ),
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
          {
            key: "body",
            header: "Response",
            align: "right",
            cell: (r) =>
              r.response_body ? (
                <ResponseBody body={r.response_body} />
              ) : (
                <span className="text-muted-foreground">–</span>
              ),
          },
        ]}
      />
    </EnvLayout>
  )
}
