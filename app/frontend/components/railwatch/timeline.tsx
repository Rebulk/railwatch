import { useMemo, useState } from "react"

import { SqlBlock } from "@/components/railwatch/sql-block"
import {
  HoverCard,
  HoverCardContent,
  HoverCardTrigger,
} from "@/components/ui/hover-card"
import { ms, usd } from "@/lib/format"
import { cn } from "@/lib/utils"
import type { TimelineEntry } from "@/types"

const colors: Record<string, string> = {
  query: "bg-sky-500",
  transaction: "bg-sky-300",
  cache_event: "bg-violet-500",
  outgoing_request: "bg-orange-500",
  mail: "bg-pink-500",
  broadcast: "bg-teal-500",
  enqueued_job: "bg-amber-500",
  view_render: "bg-emerald-500",
  storage_op: "bg-indigo-500",
  exception: "bg-red-500",
  log: "bg-neutral-400",
  span: "bg-fuchsia-500",
  attachment: "bg-lime-500",
  llm_call: "bg-cyan-400",
}

const typeLabels: Record<string, string> = {
  query: "Query",
  cache_event: "Cache",
  outgoing_request: "Outgoing",
  mail: "Mail",
  broadcast: "Broadcast",
  log: "Log",
  exception: "Exception",
  view_render: "View",
  storage_op: "Storage",
  enqueued_job: "Job",
  transaction: "Transaction",
  span: "Span",
  attachment: "Attachment",
  llm_call: "LLM",
}

const stageOrder = [
  "middleware_before",
  "action",
  "render",
  "middleware_after",
  "body",
]

const stageLabels: Record<string, string> = {
  middleware_before: "before middleware",
  action: "action",
  render: "render",
  middleware_after: "after middleware",
  body: "body",
}

// Candidate gridline intervals (ms); pick the smallest that keeps the axis
// under ~8 ticks for the current span.
const INTERVALS = [
  10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000,
]

function pickInterval(span: number) {
  const target = span / 8
  return INTERVALS.find((i) => i >= target) ?? INTERVALS[INTERVALS.length - 1]
}

function axisTicks(span: number, interval: number) {
  const out: number[] = []
  for (let t = 0; t <= span; t += interval) out.push(t)
  return out
}

// Row/axis/stage-bar all share this grid so the ms axis and gridlines line
// up exactly with every bar regardless of content.
// Phones drop the type column and shrink the label so the bars keep room.
const GRID =
  "grid grid-cols-[6rem_1fr_3.5rem] items-center gap-2 md:grid-cols-[5rem_13rem_1fr_4rem]"
const TYPE_COL = "hidden md:block"

function EntryBody({
  entry,
  showSource,
}: {
  entry: TimelineEntry
  showSource?: boolean
}) {
  const d = entry.detail ?? {}
  return (
    <div className="space-y-1.5">
      <div className="text-muted-foreground flex items-center gap-2 text-[10px] tracking-wide uppercase">
        <span>{typeLabels[entry.type] ?? entry.type}</span>
        {entry.stage && (
          <span>· {stageLabels[entry.stage] ?? entry.stage}</span>
        )}
      </div>
      {entry.type === "query" && entry.sql ? (
        <SqlBlock sql={entry.sql} wrap className="text-[11px]" />
      ) : entry.type === "cache_event" ? (
        <div className="font-mono text-xs break-all">
          {String(d.op ?? "")}{" "}
          <span className="font-semibold">{String(d.key ?? "")}</span>
        </div>
      ) : entry.type === "outgoing_request" ? (
        <div className="font-mono text-xs break-all">
          {String(d.method ?? "")} {String(d.url ?? entry.label)}
          {d.status != null && (
            <span className="text-muted-foreground"> → {String(d.status)}</span>
          )}
          {showSource && typeof d.body === "string" && d.body !== "" && (
            <pre className="bg-muted mt-1.5 max-h-48 overflow-auto rounded p-2 text-[10px] break-all whitespace-pre-wrap">
              {d.body}
            </pre>
          )}
        </div>
      ) : entry.type === "llm_call" ? (
        <div className="font-mono text-xs break-all">
          {String(d.tool ?? entry.label)}
          {d.input_tokens != null && (
            <span className="text-muted-foreground">
              {" "}
              · {String(d.input_tokens)} in / {String(d.output_tokens ?? 0)} out
            </span>
          )}
          {d.cost != null && (
            <span className="text-muted-foreground">
              {" "}
              · {usd(Number(d.cost))}
            </span>
          )}
          {d.step != null && (
            <span className="text-muted-foreground">
              {" "}
              · {String(d.workflow ?? "")} / {String(d.step)}
            </span>
          )}
          {d.error != null && (
            <div className="text-destructive mt-1">{String(d.error)}</div>
          )}
        </div>
      ) : entry.type === "mail" ? (
        <div className="font-mono text-xs break-all">
          {String(d.subject ?? entry.label)}
        </div>
      ) : entry.type === "log" ? (
        <div className="font-mono text-xs break-words">
          <span className="text-muted-foreground uppercase">
            {String(d.level ?? "")}
          </span>{" "}
          {String(d.message ?? entry.label)}
        </div>
      ) : entry.type === "exception" ? (
        <div className="text-destructive font-mono text-xs break-words">
          {entry.label}
        </div>
      ) : (
        <div className="font-mono text-xs break-words">{entry.label}</div>
      )}
      <div className="text-muted-foreground flex flex-wrap gap-x-3 text-[11px] tabular-nums">
        <span>+{ms(entry.offset)}</span>
        {entry.duration != null && <span>{ms(entry.duration)}</span>}
      </div>
      {showSource && entry.source && (
        <div className="text-muted-foreground border-t pt-1 font-mono text-[11px] break-all">
          {entry.source}
        </div>
      )}
    </div>
  )
}

function Gridlines({ ticks, span }: { ticks: number[]; span: number }) {
  return (
    <>
      {ticks.map((t) => (
        <div
          key={t}
          className="bg-border/60 pointer-events-none absolute top-0 h-full w-px"
          style={{ left: `${(t / span) * 100}%` }}
        />
      ))}
    </>
  )
}

export function Timeline({
  entries,
  total,
  stages,
}: {
  entries: TimelineEntry[]
  total: number
  stages: Record<string, number>
}) {
  const [hidden, setHidden] = useState<Set<string>>(new Set())
  const [expanded, setExpanded] = useState<string | null>(null)

  const span = Math.max(
    total,
    ...entries.map((e) => e.offset + (e.duration ?? 0)),
    1,
  )
  const interval = pickInterval(span)
  const ticks = axisTicks(span, interval)

  const counts = useMemo(() => {
    const c = new Map<string, number>()
    for (const e of entries) c.set(e.type, (c.get(e.type) ?? 0) + 1)
    return c
  }, [entries])

  const visible = entries.filter((e) => !hidden.has(e.type))

  function toggleType(type: string) {
    setHidden((prev) => {
      const next = new Set(prev)
      if (next.has(type)) next.delete(type)
      else next.add(type)
      return next
    })
  }

  const stageBars = stageOrder
    .filter((s) => stages[s] !== undefined)
    .reduce<{ name: string; start: number; width: number }[]>((acc, s) => {
      const start =
        acc.length > 0
          ? acc[acc.length - 1].start + acc[acc.length - 1].width
          : 0
      acc.push({ name: s, start, width: stages[s] })
      return acc
    }, [])

  return (
    <div className="space-y-2">
      {counts.size > 0 && (
        <div className="flex flex-wrap items-center gap-1.5">
          {[...counts.entries()].map(([type, n]) => (
            <button
              key={type}
              type="button"
              onClick={() => toggleType(type)}
              className={cn(
                "flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[10px] font-medium transition-colors",
                hidden.has(type)
                  ? "text-muted-foreground opacity-50"
                  : "hover:bg-muted/60",
              )}
            >
              <span
                className={cn(
                  "size-1.5 rounded-full",
                  colors[type] ?? "bg-neutral-500",
                )}
              />
              {typeLabels[type] ?? type}
              <span className="text-muted-foreground tabular-nums">{n}</span>
            </button>
          ))}
        </div>
      )}

      <div className={cn(GRID, "px-2 text-[10px]")}>
        <div className={TYPE_COL} />
        <div />
        <div className="relative h-4 select-none">
          {ticks.map((t) => (
            <span
              key={t}
              className="text-muted-foreground absolute -translate-x-1/2 tabular-nums"
              style={{ left: `${(t / span) * 100}%` }}
            >
              {ms(t, 0)}
            </span>
          ))}
        </div>
        <div />
      </div>

      <div className={cn(GRID, "px-2")}>
        <div className={TYPE_COL} />
        <div />
        <div className="bg-muted/40 relative h-5 overflow-hidden rounded text-[10px]">
          <Gridlines ticks={ticks} span={span} />
          {stageBars.map((s) => (
            <div
              key={s.name}
              className="border-background bg-primary/20 absolute top-0 flex h-full items-center overflow-hidden border-r px-1 whitespace-nowrap"
              style={{
                left: `${(s.start / span) * 100}%`,
                width: `${(s.width / span) * 100}%`,
              }}
              title={`${stageLabels[s.name] ?? s.name} ${ms(s.width)}`}
            >
              {stageLabels[s.name] ?? s.name} {ms(s.width, 0)}
            </div>
          ))}
        </div>
        <div />
      </div>

      <div className="max-h-[32rem] overflow-y-auto rounded-lg border">
        {entries.length === 0 && (
          <div className="text-muted-foreground p-4 text-center text-sm">
            No child events recorded.
          </div>
        )}
        {entries.length > 0 && visible.length === 0 && (
          <div className="text-muted-foreground p-4 text-center text-sm">
            No events match the active filters.
          </div>
        )}
        {visible.map((e) => {
          const key = `${e.type}-${e.id}`
          const isSlow = span > 0 && (e.duration ?? 0) / span > 0.1
          const isException = e.type === "exception"
          return (
            <div
              key={key}
              className="border-b last:border-b-0"
              style={{
                contentVisibility: "auto",
                containIntrinsicSize: "0 28px",
              }}
            >
              <HoverCard openDelay={150}>
                <HoverCardTrigger asChild>
                  <button
                    type="button"
                    onClick={() => setExpanded(expanded === key ? null : key)}
                    className={cn(
                      GRID,
                      "hover:bg-muted/40 w-full px-2 py-1 text-left text-xs",
                    )}
                  >
                    <span
                      className={cn(
                        "text-muted-foreground truncate font-mono",
                        TYPE_COL,
                      )}
                    >
                      {typeLabels[e.type] ?? e.type}
                    </span>
                    {e.type === "query" && e.sql ? (
                      <SqlBlock sql={e.sql} />
                    ) : (
                      <span className="truncate font-mono">{e.label}</span>
                    )}
                    <div className="bg-muted/30 relative h-3 rounded">
                      <Gridlines ticks={ticks} span={span} />
                      {isException ? (
                        <div
                          className="absolute top-1/2 size-2.5 -translate-x-1/2 -translate-y-1/2 rotate-45 bg-red-500"
                          style={{
                            left: `${Math.min(100, (e.offset / span) * 100)}%`,
                          }}
                        />
                      ) : (
                        <div
                          className={cn(
                            "absolute top-0 h-full rounded",
                            colors[e.type] ?? "bg-neutral-500",
                            isSlow
                              ? "ring-foreground/30 opacity-100 ring-1 ring-inset"
                              : "opacity-70",
                          )}
                          style={{
                            left: `${Math.min(100, (e.offset / span) * 100)}%`,
                            width: `${Math.max(0.3, ((e.duration ?? 0) / span) * 100)}%`,
                          }}
                        />
                      )}
                    </div>
                    <span
                      className={cn(
                        "text-muted-foreground text-right tabular-nums",
                        isSlow && "text-foreground font-semibold",
                      )}
                    >
                      {e.duration != null ? ms(e.duration) : "–"}
                    </span>
                  </button>
                </HoverCardTrigger>
                <HoverCardContent className="w-80" align="start">
                  <EntryBody entry={e} />
                </HoverCardContent>
              </HoverCard>
              {expanded === key && (
                <div className="bg-muted/20 border-t px-4 py-2">
                  <EntryBody entry={e} showSource />
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
