import { Link, usePage } from "@inertiajs/react"
import { Braces } from "lucide-react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { StatusBadge } from "@/components/railwatch/status-badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { SeriesPoint, SharedProps, SummaryWithDelta } from "@/types"

interface Facet {
  key: string
  count: number
  values: [string, number][]
}
interface Sample {
  id: number
  name: string
  duration: number
  status: string | null
  attributes: Record<string, unknown>
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
}
interface Props {
  group_hash: string
  name: string | null
  summary: SummaryWithDelta
  series: SeriesPoint[]
  facets: Facet[]
  samples: Sample[]
}

function Attributes({ attributes }: { attributes: Record<string, unknown> }) {
  const entries = Object.entries(attributes)
  if (entries.length === 0)
    return <span className="text-muted-foreground text-xs">–</span>
  return (
    <span className="flex flex-wrap gap-1">
      {entries.map(([key, value]) => (
        <span
          key={key}
          className="bg-muted rounded-sm px-1.5 font-mono text-[10px]"
        >
          {key}={String(value)}
        </span>
      ))}
    </span>
  )
}

export default function SpanShow(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const current = p.summary.current

  return (
    <EnvLayout
      title={p.name ?? "Span"}
      crumbs={[
        {
          title: "Spans",
          href: R.applicationEnvironmentSpansPath(a, e, { window }),
        },
        { title: p.name ?? "Span", href: "#" },
      ]}
    >
      <PageHeader
        title={<span className="font-mono">{p.name ?? "Span"}</span>}
        description="Every recording of this span in the window."
      />
      <StatStrip>
        <Stat
          label="Recorded"
          value={count(current.count)}
          delta={{
            current: current.count,
            previous: p.summary.previous.count,
            goodDirection: "up",
          }}
          deltaCaption="vs previous period"
        />
        <Stat
          label="Failed"
          value={count(current.errors)}
          tone={current.errors ? "destructive" : undefined}
        />
        <Stat
          label="p95"
          value={ms(current.p95 / 1000, 2)}
          hint={`p99 ${ms(current.p99 / 1000, 2)}`}
        />
        <Stat
          label="Max"
          value={ms(current.max / 1000, 2)}
          hint={`avg ${ms(current.avg / 1000, 2)}`}
        />
      </StatStrip>
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel
          legend="outcome"
          label="Recordings"
          seriesLabel="Spans"
          data={p.series}
        />
        <DurationPanel label="Duration" data={p.series} />
      </div>
      <Card>
        <CardHeader>
          <CardTitle>Attributes</CardTitle>
        </CardHeader>
        <CardContent>
          <DataTable
            rows={p.facets}
            rowKey={(f) => f.key}
            empty={
              <EmptyState
                icon={Braces}
                title="No attributes recorded"
                description="Pass a hash to Railwatch.span to tag each recording."
              />
            }
            columns={[
              {
                key: "k",
                header: "Key",
                cell: (f) => <span className="font-mono text-xs">{f.key}</span>,
              },
              {
                key: "v",
                header: "Most common values",
                cell: (f) => (
                  <span className="flex flex-wrap gap-1">
                    {f.values.map(([value, n]) => (
                      <span
                        key={value}
                        className="bg-muted rounded-sm px-1.5 font-mono text-[10px]"
                      >
                        {value}
                        <span className="text-muted-foreground"> ×{n}</span>
                      </span>
                    ))}
                  </span>
                ),
              },
              {
                key: "n",
                header: "Spans",
                align: "right",
                cell: (f) => count(f.count),
              },
            ]}
          />
        </CardContent>
      </Card>
      <DataTable
        rows={p.samples}
        rowKey={(s) => s.id}
        empty={
          <EmptyState
            icon={Braces}
            title="No recordings in this window"
            description="Widen the time window to see older recordings of this span."
          />
        }
        columns={[
          {
            key: "when",
            header: "When",
            cell: (s) => <span className="text-xs">{when(s.occurred_at)}</span>,
          },
          {
            key: "status",
            header: "Status",
            cell: (s) => <StatusBadge outcome={s.status} />,
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (s) =>
              s.execution_id ? (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={R.applicationEnvironmentRequestPath(
                    a,
                    e,
                    s.execution_id,
                  )}
                >
                  {s.execution_preview}
                </Link>
              ) : (
                <span className="text-muted-foreground text-xs">–</span>
              ),
          },
          {
            key: "attrs",
            hideOnMobile: true,
            header: "Attributes",
            cell: (s) => <Attributes attributes={s.attributes} />,
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (s) => ms(s.duration, 2),
          },
        ]}
      />
    </EnvLayout>
  )
}
