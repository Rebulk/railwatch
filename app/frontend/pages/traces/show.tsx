import { Link, usePage } from "@inertiajs/react"

import { CopyId } from "@/components/railwatch/copy-id"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { KindBadge } from "@/components/railwatch/status-badge"
import EnvLayout from "@/layouts/env-layout"
import { executionPath } from "@/lib/execution-path"
import { count, ms, statusTone } from "@/lib/format"
import { cn } from "@/lib/utils"
import type { SharedProps } from "@/types"

interface Outgoing {
  id: number
  method: string | null
  url: string
  status_code: number | null
  duration: number | null
  offset: number
}
interface TraceExecution {
  execution_id: string
  kind: string
  name: string
  status: number | null
  outcome: string | null
  parent_id: string | null
  server: string | null
  occurred_at: string
  duration: number
  offset: number
  outgoing: Outgoing[]
}
interface Node {
  execution: TraceExecution
  children: Node[]
}
interface Props {
  trace_id: string
  roots: Node[]
  span_count: number
  services: string[]
  duration: number
}

interface Row {
  key: string
  depth: number
  kind: string
  label: string
  server: string | null
  offset: number
  duration: number
  href: string | null
  failed: boolean
}

const kindLabels: Record<string, string> = {
  request: "REQ",
  job_attempt: "JOB",
  scheduled_task: "TASK",
  command: "CMD",
  outgoing_request: "HTTP",
}

// Depth-first walk of the trace: each execution, then the HTTP calls it made
// (one level in, and not clickable — the hop they led to is a row of its own
// if that service reports to Railwatch), then its child executions.
function flatten(nodes: Node[], a: number, e: number, depth = 0): Row[] {
  return nodes.flatMap((node) => {
    const x = node.execution
    return [
      {
        key: x.execution_id,
        depth,
        kind: x.kind,
        label: x.name,
        server: x.server,
        offset: x.offset,
        duration: x.duration,
        href: executionPath({
          applicationId: a,
          environmentId: e,
          source: x.kind,
          executionId: x.execution_id,
        })!,
        failed: statusTone(x.status, x.outcome) === "destructive",
      },
      ...x.outgoing.map((o) => ({
        key: `o-${o.id}`,
        depth: depth + 1,
        kind: "outgoing_request",
        label: `${o.method ?? ""} ${o.url}`.trim(),
        server: null,
        offset: o.offset,
        duration: o.duration ?? 0,
        href: null,
        failed: statusTone(o.status_code) === "destructive",
      })),
      ...flatten(node.children, a, e, depth + 1),
    ]
  })
}

// One waterfall row. Phones stack the bar under the name/duration line;
// from md up the three parts sit on one line against a shared time scale.
function WaterfallRow({ row, scale }: { row: Row; scale: number }) {
  const body = (
    <>
      <span
        className="col-start-1 row-start-1 flex min-w-0 items-center gap-1.5"
        style={{ paddingLeft: `${row.depth * 0.75}rem` }}
      >
        <KindBadge tone={row.failed ? "destructive" : "muted"}>
          {kindLabels[row.kind] ?? row.kind}
        </KindBadge>
        <span className="truncate font-mono">{row.label}</span>
        {row.server && (
          <span className="text-muted-foreground hidden shrink-0 font-mono text-[10px] sm:inline">
            {row.server}
          </span>
        )}
      </span>
      <span className="col-start-2 row-start-1 text-right font-mono tabular-nums md:col-start-3">
        {ms(row.duration)}
      </span>
      <span className="bg-muted/30 col-span-2 col-start-1 row-start-2 h-2 rounded md:col-span-1 md:col-start-2 md:row-start-1 md:h-3">
        <span
          className={cn(
            "block h-full rounded",
            row.failed ? "bg-danger" : row.href ? "bg-primary" : "bg-ok",
          )}
          style={{
            marginLeft: `${Math.min(99, (row.offset / scale) * 100)}%`,
            width: `${Math.max(0.5, (row.duration / scale) * 100)}%`,
          }}
        />
      </span>
    </>
  )
  const className =
    "grid grid-cols-[1fr_4rem] items-center gap-x-2 gap-y-1 border-b px-2 py-1.5 text-xs last:border-b-0 md:grid-cols-[minmax(0,18rem)_1fr_4rem]"
  return row.href ? (
    <Link href={row.href} className={cn(className, "hover:bg-muted/40")}>
      {body}
    </Link>
  ) : (
    <div className={cn(className, "text-muted-foreground")}>{body}</div>
  )
}

export default function TraceShow(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const rows = flatten(p.roots, a, e)
  const executions = rows.filter((r) => r.href !== null)
  const errors = executions.filter((r) => r.failed).length
  const scale = Math.max(p.duration, 1)

  return (
    <EnvLayout title="Trace" crumbs={[{ title: "Trace", href: "#" }]}>
      <PageHeader
        withWindow={false}
        title={
          <span className="flex min-w-0 items-center gap-1">
            <span className="truncate font-mono text-base md:text-xl">
              {p.trace_id}
            </span>
            <CopyId value={p.trace_id} label="" />
          </span>
        }
        description="Every execution that shares this trace id, nested by the call that started it."
      />
      <StatStrip>
        <Stat
          label="Executions"
          value={count(executions.length)}
          hint={`${p.span_count} spans`}
        />
        <Stat
          label="Services"
          value={count(p.services.length)}
          hint={p.services.join(" · ")}
        />
        <Stat label="Total duration" value={ms(p.duration)} />
        <Stat
          label="Errors"
          value={count(errors)}
          tone={errors ? "destructive" : undefined}
        />
      </StatStrip>
      <div className="bg-card -mx-3 overflow-hidden border-y md:mx-0 md:rounded-lg md:border">
        {rows.length === 0 ? (
          <EmptyState
            title="Nothing in this trace"
            description="No execution reported this trace id."
          />
        ) : (
          rows.map((row) => (
            <WaterfallRow key={row.key} row={row} scale={scale} />
          ))
        )}
      </div>
    </EnvLayout>
  )
}
