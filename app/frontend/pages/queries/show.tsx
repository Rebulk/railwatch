import { Link, usePage } from "@inertiajs/react"
import { Database } from "lucide-react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { Mono } from "@/components/railwatch/code"
import { CopyId } from "@/components/railwatch/copy-id"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, when } from "@/lib/format"
import { cn } from "@/lib/utils"
import * as R from "@/routes"
import type { SeriesPoint, SharedProps, Summary } from "@/types"

import { DiagnosticsPanel } from "./diagnostics-panel"
import type { QueryDiagnostics } from "./diagnostics-types"

interface Sample {
  id: number
  sql: string
  duration: number
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
  source: string | null
  connection: string | null
  row_count: number | null
}
// The newest sample in the group the gem captured a plan for. Only slow
// queries get one, so it's usually not the newest sample overall.
interface Explain {
  plan: string
  occurred_at: string
  duration: number
  execution_id: string | null
  adapter: string | null
  connection: string | null
  truncated?: boolean
}
interface Props {
  group_hash: string
  sql: string | null
  summary: Summary
  series: SeriesPoint[]
  sources: [string, number][]
  callers: [string, number][]
  roles: [string, number][]
  explain: Explain | null
  diagnostics: QueryDiagnostics
  samples: Sample[]
}

export default function QueryShow(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const s = p.summary
  const plan = p.explain?.plan ?? ""
  const observations = p.diagnostics.recommendations.filter(
    (r) => r.basis === "plan",
  )
  return (
    <EnvLayout
      title="Query"
      crumbs={[
        {
          title: "Queries",
          href: R.applicationEnvironmentQueriesPath(a, e, { window }),
        },
        { title: "Query", href: "#" },
      ]}
    >
      <PageHeader
        title="Query"
        actions={p.sql ? <CopyId value={p.sql} label="Copy SQL" /> : undefined}
      />
      <pre className="bg-muted/60 overflow-x-auto rounded-lg p-3 font-mono text-xs whitespace-pre-wrap">
        {p.sql ?? "No samples in this window."}
      </pre>
      {p.roles.length > 0 && (
        <div className="text-muted-foreground font-mono text-[11px]">
          {p.roles.map(([role, n]) => `${role} ${count(n)}`).join(" · ")}
        </div>
      )}
      <StatStrip>
        <Stat label="Executions" value={count(s.count)} />
        <Stat label="Avg" value={ms(s.avg / 1000, 2)} />
        <Stat
          label="p95"
          value={ms(s.p95 / 1000, 2)}
          hint={`p99 ${ms(s.p99 / 1000, 2)}`}
        />
        <Stat label="Max" value={ms(s.max / 1000, 2)} />
      </StatStrip>
      <DiagnosticsPanel diagnostics={p.diagnostics} />
      <Card>
        <CardHeader>
          <CardTitle>Query plan</CardTitle>
        </CardHeader>
        <CardContent>
          {p.explain ? (
            <>
              <div className="text-muted-foreground mb-2 font-mono text-[11px]">
                {when(p.explain.occurred_at)} · {ms(p.explain.duration, 2)}
                {" · "}
                {p.explain.connection ?? "Connection not captured"}
                {" · "}
                {p.explain.adapter ?? "Adapter not captured"}
                {p.explain.execution_id && (
                  <>
                    {" · "}
                    <Link
                      className="hover:underline"
                      href={R.applicationEnvironmentRequestPath(
                        a,
                        e,
                        p.explain.execution_id,
                      )}
                    >
                      {p.explain.execution_id}
                    </Link>
                  </>
                )}
              </div>
              {p.explain.truncated && (
                <p className="text-muted-foreground mb-2 text-xs">
                  The stored plan exceeds the display limit; this is an excerpt.
                </p>
              )}
              <div className="bg-muted/60 overflow-x-auto rounded-lg p-3 font-mono text-xs">
                {plan.split("\n").map((row, i) => {
                  const hits = observations.filter((observation) =>
                    observation.evidence.some(
                      (evidence) => evidence.line === i + 1,
                    ),
                  )
                  return (
                    <div
                      key={i}
                      className={cn(
                        "py-0.5",
                        hits.length > 0 && "border-warning border-l-2 pl-2",
                      )}
                    >
                      <div
                        className={cn(
                          "whitespace-pre",
                          hits.length > 0 && "text-warning",
                        )}
                      >
                        {row}
                      </div>
                      {hits.map((w) => (
                        <div
                          key={w.id}
                          className="text-warning/80 mt-0.5 text-[11px] whitespace-normal"
                        >
                          {w.title}
                        </div>
                      ))}
                    </div>
                  )
                })}
              </div>
            </>
          ) : (
            <p className="text-muted-foreground text-xs">
              Enable plans for slow queries with{" "}
              <Mono>RAILWATCH_CAPTURE_QUERY_EXPLAIN=true</Mono> (threshold{" "}
              <Mono>RAILWATCH_EXPLAIN_THRESHOLD_MS</Mono>, default 100ms)
            </p>
          )}
        </CardContent>
      </Card>
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel
          legend="outcome"
          label="Executions"
          seriesLabel="Executions"
          data={p.series}
        />
        <DurationPanel label="Duration" data={p.series} />
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Called from</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.sources}
              rowKey={([src]) => src}
              empty={
                <EmptyState
                  icon={Database}
                  title="No source captured"
                  description="A backtrace location wasn't available for this query."
                />
              }
              columns={[
                {
                  key: "s",
                  header: "Source",
                  cell: ([src]) => (
                    <span className="font-mono text-xs">{src}</span>
                  ),
                },
                {
                  key: "n",
                  header: "Count",
                  align: "right",
                  cell: ([, n]) => n,
                },
              ]}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Executions</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.callers}
              rowKey={([c]) => c}
              columns={[
                {
                  key: "c",
                  header: "Execution",
                  cell: ([c]) => <span className="font-mono text-xs">{c}</span>,
                },
                {
                  key: "n",
                  header: "Count",
                  align: "right",
                  cell: ([, n]) => n,
                },
              ]}
            />
          </CardContent>
        </Card>
      </div>
      <DataTable
        rows={p.samples}
        rowKey={(x) => x.id}
        columns={[
          {
            key: "when",
            header: "When",
            cell: (x) => <span className="text-xs">{when(x.occurred_at)}</span>,
          },
          {
            key: "in",
            header: "In",
            cell: (x) =>
              x.execution_id ? (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={R.applicationEnvironmentRequestPath(
                    a,
                    e,
                    x.execution_id,
                  )}
                >
                  {x.execution_preview}
                </Link>
              ) : (
                <span className="text-muted-foreground text-xs">–</span>
              ),
          },
          {
            key: "rows",
            hideOnMobile: true,
            header: "Rows",
            align: "right",
            cell: (x) => x.row_count ?? "–",
          },
          {
            key: "conn",
            hideOnMobile: true,
            header: "DB",
            cell: (x) => x.connection,
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (x) => ms(x.duration, 2),
          },
        ]}
      />
    </EnvLayout>
  )
}
