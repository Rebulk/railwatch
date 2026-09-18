import { Link, router, usePage } from "@inertiajs/react"
import { Mail } from "lucide-react"

import { VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Badge } from "@/components/ui/badge"
import { usePercentile } from "@/hooks/use-percentile"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { GroupRow, SeriesPoint, SharedProps } from "@/types"

interface MailRow {
  id: number
  mailer: string
  subject: string
  to: number
  cc: number
  bcc: number
  attachments: number
  delivery_method: string | null
  duration: number
  failed: boolean
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
}
interface Props {
  mailers: GroupRow[]
  series: SeriesPoint[]
  recent: MailRow[]
  q: string
}

export default function Mails(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id
  const mailHref = (m: MailRow) =>
    m.execution_id
      ? R.applicationEnvironmentRequestPath(a, e, m.execution_id)
      : null
  return (
    <EnvLayout title="Mail">
      <PageHeader
        title="Mail"
        description="Action Mailer deliveries: recipients, delivery method, render and send time."
        actions={<PercentilePicker />}
      />
      <VolumePanel
        legend="outcome"
        label="Deliveries"
        seriesLabel="Deliveries"
        data={p.series}
      />
      <DataTable
        rows={p.mailers}
        rowKey={(m) => m.group_hash}
        empty={
          <EmptyState
            icon={Mail}
            title="No mail sent in this window"
            description="ActionMailer deliveries appear here as your app sends them."
          />
        }
        columns={[
          {
            key: "m",
            header: "Mailer",
            cell: (m) => <span className="font-mono text-xs">{m.name}</span>,
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (m) => <SparklineCell data={m.sparkline} />,
          },
          {
            key: "n",
            header: "Sent",
            align: "right",
            cell: (m) => count(m.count),
          },
          {
            key: "f",
            hideOnMobile: true,
            header: "Failed",
            align: "right",
            cell: (m) => m.errors,
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (m) => ms(m.avg),
          },
          {
            key: percentile,
            header: percentile,
            align: "right",
            cell: (m) => (
              <span className="font-semibold">{ms(m[percentile])}</span>
            ),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Recent</h2>
      <FilterBar
        value={p.q}
        fields={[
          { key: "mailer", label: "Mailer" },
          { key: "kind", label: "Kind" },
        ]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentMailsPath(a, e, {
              window,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="mailer:WidgetMailer kind:smtp"
      />
      <DataTable
        rows={p.recent}
        rowKey={(m) => m.id}
        empty={
          <EmptyState
            icon={Mail}
            title="No mail sent in this window"
            description="ActionMailer deliveries appear here as your app sends them."
          />
        }
        keyboardNav={{
          onOpen: (m, opts) => {
            const href = mailHref(m)
            if (!href) return
            if (opts?.newTab) globalThis.window.open(href, "_blank")
            else router.visit(href)
          },
        }}
        columns={[
          {
            key: "when",
            header: "When",
            cell: (m) => <span className="text-xs">{when(m.occurred_at)}</span>,
          },
          {
            key: "m",
            header: "Mailer",
            cell: (m) => <span className="font-mono text-xs">{m.mailer}</span>,
          },
          {
            key: "s",
            header: "Subject",
            cell: (m) => (
              <span className="line-clamp-1 text-xs">{m.subject}</span>
            ),
          },
          {
            key: "to",
            hideOnMobile: true,
            header: "To/CC/BCC",
            align: "right",
            cell: (m) => `${m.to}/${m.cc}/${m.bcc}`,
          },
          {
            key: "att",
            hideOnMobile: true,
            header: "Att.",
            align: "right",
            cell: (m) => m.attachments,
          },
          {
            key: "dm",
            hideOnMobile: true,
            header: "Via",
            cell: (m) => m.delivery_method,
          },
          {
            key: "st",
            header: "",
            cell: (m) =>
              m.failed ? <Badge variant="destructive">failed</Badge> : null,
          },
          {
            key: "d",
            hideOnMobile: true,
            header: "Duration",
            align: "right",
            cell: (m) => ms(m.duration),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (m) => {
              const href = mailHref(m)
              return href ? (
                <Link className="font-mono text-xs hover:underline" href={href}>
                  {m.execution_preview}
                </Link>
              ) : null
            },
          },
        ]}
      />
    </EnvLayout>
  )
}
