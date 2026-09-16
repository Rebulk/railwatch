import { Fragment, useState } from "react"

import { SourceLink } from "@/components/railwatch/source-link"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import type { ExceptionDetail, Frame, TimelineEntry } from "@/types"

// A hashed build asset -- "assets/index-Bq1x9K2v.js", what a browser frame
// points at in production. It is the app's own code, but not at any path
// that exists in the repository, so there is nothing to link it to until
// Railwatch can resolve it through a source map (docs/roadmap.md); until then
// it is shown exactly as the browser named it.
const HASHED_ASSET = /-[A-Za-z0-9_-]{8,}\.(?:js|mjs|cjs|css)$/

function FrameRow({
  frame,
  deploy,
  open,
  onToggle,
}: {
  frame: Frame
  deploy?: string | null
  open: boolean
  onToggle: () => void
}) {
  const lines = frame.code ? Object.entries(frame.code) : []
  const linkable = frame.in_app && !HASHED_ASSET.test(frame.file)
  return (
    <div
      className={cn(
        "border-b last:border-b-0",
        frame.in_app ? "bg-background" : "bg-muted/40",
      )}
    >
      <div className="hover:bg-muted/60 flex w-full items-center gap-2 px-3 py-1.5 font-mono text-xs">
        {linkable && (
          <SourceLink
            location={`${frame.file}:${frame.line}`}
            deploy={deploy}
          />
        )}
        <button
          type="button"
          onClick={onToggle}
          className="flex min-w-0 flex-1 items-center gap-2 text-left"
        >
          {!linkable && (
            <span className="text-muted-foreground truncate">
              {frame.file}:{frame.line}
            </span>
          )}
          <span className="text-muted-foreground ml-auto truncate">
            in {frame.function}
          </span>
          {frame.in_app && (
            <Badge variant="outline" className="shrink-0 text-[10px]">
              app
            </Badge>
          )}
        </button>
      </div>
      {open && lines.length > 0 && (
        <pre className="bg-muted/60 overflow-x-auto px-3 py-2 font-mono text-xs leading-5">
          {lines.map(([n, src]) => (
            <div
              key={n}
              className={cn(
                "flex gap-3 border-l-2 border-transparent pl-2",
                Number(n) === frame.line &&
                  "border-destructive bg-destructive/10 font-semibold",
              )}
            >
              <span className="text-muted-foreground w-10 shrink-0 text-right select-none">
                {n}
              </span>
              <span className="whitespace-pre">{src}</span>
            </div>
          ))}
        </pre>
      )}
    </div>
  )
}

export function Frames({
  frames,
  deploy,
}: {
  frames: Frame[]
  deploy?: string | null
}) {
  const appIndexes = frames.flatMap((f, i) => (f.in_app ? [i] : []))
  const [open, setOpen] = useState<Set<number>>(
    new Set(appIndexes.length > 0 ? appIndexes : [0]),
  )
  const [showAll, setShowAll] = useState(false)
  const visible = showAll ? frames : frames.filter((f, i) => f.in_app || i < 3)

  function toggle(idx: number) {
    setOpen((prev) => {
      const next = new Set(prev)
      if (next.has(idx)) next.delete(idx)
      else next.add(idx)
      return next
    })
  }

  return (
    <div className="overflow-hidden rounded-lg border">
      {visible.map((f) => {
        const idx = frames.indexOf(f)
        return (
          <FrameRow
            key={idx}
            frame={f}
            deploy={deploy}
            open={open.has(idx)}
            onToggle={() => toggle(idx)}
          />
        )
      })}
      {visible.length < frames.length && (
        <button
          type="button"
          className="text-muted-foreground w-full px-3 py-1.5 text-left text-xs hover:underline"
          onClick={() => setShowAll(true)}
        >
          Show {frames.length - visible.length} framework frames
        </button>
      )}
    </div>
  )
}

export function ExceptionCard({
  exception,
  deploy,
}: {
  exception: ExceptionDetail
  deploy?: string | null
}) {
  return (
    <div className="space-y-3">
      <div>
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-mono text-sm font-semibold">
            {exception.class_name}
          </span>
          <Badge variant={exception.handled ? "secondary" : "destructive"}>
            {exception.handled ? "handled" : "unhandled"}
          </Badge>
          {exception.severity && (
            <Badge variant="outline">{exception.severity}</Badge>
          )}
          {exception.source && (
            <span className="text-muted-foreground font-mono text-xs">
              {exception.source}
            </span>
          )}
        </div>
        <p className="mt-1 font-mono text-sm break-words">
          {exception.message}
        </p>
        {exception.cause && (
          <p className="text-muted-foreground mt-1 font-mono text-xs">
            caused by {exception.cause.class}: {exception.cause.message}
          </p>
        )}
      </div>
      <Frames frames={exception.frames} deploy={deploy} />
      {exception.locals && Object.keys(exception.locals).length > 0 && (
        <div className="overflow-hidden rounded-lg border">
          <div className="label-caps border-b px-3 py-1.5">
            Local variables at the raise site
          </div>
          <dl className="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 px-3 py-2 font-mono text-xs">
            {Object.entries(exception.locals).map(([name, value]) => (
              <Fragment key={name}>
                <dt className="text-muted-foreground">{name}</dt>
                <dd className="break-all">{value}</dd>
              </Fragment>
            ))}
          </dl>
        </div>
      )}
      {exception.context && exception.context !== "{}" && (
        <pre className="bg-muted/60 overflow-x-auto rounded-lg p-3 font-mono text-xs">
          {exception.context}
        </pre>
      )}
    </div>
  )
}

const crumbColors: Record<string, string> = {
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
}

// Sentry-style breadcrumbs: what the execution did in the run-up to the
// exception, oldest first, each with its offset from the start.
export function Breadcrumbs({ entries }: { entries: TimelineEntry[] }) {
  if (entries.length === 0) return null
  return (
    <div className="overflow-hidden rounded-lg border">
      <div className="label-caps border-b px-3 py-1.5">
        Breadcrumbs · {entries.length} events before the exception
      </div>
      <ol className="divide-y">
        {entries.map((e) => (
          <li
            key={`${e.type}-${e.id}`}
            className="grid grid-cols-[3.5rem_5rem_1fr_4rem] items-center gap-2 px-3 py-1 font-mono text-xs"
          >
            <span className="text-muted-foreground tabular-nums">
              +{e.offset.toFixed(1)}ms
            </span>
            <span className="text-muted-foreground flex items-center gap-1.5 truncate">
              <span
                className={cn(
                  "inline-block size-1.5 shrink-0 rounded-full",
                  crumbColors[e.type] ?? "bg-neutral-500",
                )}
              />
              {e.type.replace("_", " ")}
            </span>
            <span className="truncate">{e.label}</span>
            <span className="text-muted-foreground text-right tabular-nums">
              {e.duration != null ? `${e.duration.toFixed(1)}ms` : ""}
            </span>
          </li>
        ))}
      </ol>
    </div>
  )
}

export interface BrowserCrumb {
  at: number
  kind: string
  text: string
}

const browserCrumbColors: Record<string, string> = {
  console: "bg-red-500",
  click: "bg-violet-500",
  navigate: "bg-sky-500",
}

// The browser's half of the same idea: what the user did in the run-up to a
// JavaScript error -- console errors, clicks, Inertia navigations -- offset
// from the first of them, since a browser error has no execution whose
// timeline would mean anything (its execution is the beacon that carried it).
export function BrowserBreadcrumbs({ crumbs }: { crumbs: BrowserCrumb[] }) {
  if (crumbs.length === 0) return null
  const start = crumbs[0].at
  return (
    <div className="overflow-hidden rounded-lg border">
      <div className="label-caps border-b px-3 py-1.5">
        Breadcrumbs · {crumbs.length} events before the error
      </div>
      <ol className="divide-y">
        {crumbs.map((c, i) => (
          <li
            key={`${c.at}-${c.kind}-${i}`}
            className="grid grid-cols-[3.5rem_5rem_1fr] items-center gap-2 px-3 py-1 font-mono text-xs"
          >
            <span className="text-muted-foreground tabular-nums">
              +{((c.at - start) / 1000).toFixed(1)}s
            </span>
            <span className="text-muted-foreground flex items-center gap-1.5 truncate">
              <span
                className={cn(
                  "inline-block size-1.5 shrink-0 rounded-full",
                  browserCrumbColors[c.kind] ?? "bg-neutral-500",
                )}
              />
              {c.kind}
            </span>
            <span className="truncate">{c.text}</span>
          </li>
        ))}
      </ol>
    </div>
  )
}
