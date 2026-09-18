import { Link, router, usePage } from "@inertiajs/react"
import { FileText } from "lucide-react"
import { useState } from "react"

import { CursorLoadMore } from "@/components/railwatch/cursor-load-more"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { SavedViewsMenu } from "@/components/railwatch/saved-views"
import { Segmented, SegmentedItem } from "@/components/railwatch/segmented"
import { LevelBadge } from "@/components/railwatch/status-badge"
import EnvLayout from "@/layouts/env-layout"
import { parseFilter, serializeFilter } from "@/lib/filter"
import { count, when } from "@/lib/format"
import { cn } from "@/lib/utils"
import * as R from "@/routes"
import type { CursorMeta, SharedProps } from "@/types"

interface LogRow {
  id: number
  level: string
  message: string
  tags: string[]
  occurred_at: string
  execution_id: string | null
  execution_source: string | null
  execution_preview: string | null
  source: string | null
  tenant: string | null
  user_ref: string | null
  context: string | null
}
interface Props {
  logs: LogRow[]
  counts: Record<string, number>
  // id -> the matching part of the message, each hit wrapped in MARK. Only
  // present for rows the full-text search actually matched.
  highlights: Record<number, string>
  pagination: CursorMeta
  q: string
}

// Telemetry::Log::SNIPPET_MARK: one character opens and closes every hit, so
// the odd-numbered pieces of the split are the ones to mark.
const MARK = "\u001f"

// Long lines (structured events, stack dumps) are clamped to a few rows so
// the table stays scannable, especially on phones where the message column
// is narrow. Tapping the message toggles the full text. Short lines have
// nothing to expand, so they are plain.
const CLAMP_AT = 160

function LogMessage({
  message,
  highlight,
  tags,
}: {
  message: string
  highlight?: string
  tags: string[]
}) {
  const [open, setOpen] = useState(false)
  const long = message.length > CLAMP_AT || message.includes("\n")
  const body = (
    <span
      className={cn(
        "font-mono text-xs break-all whitespace-pre-wrap",
        long && !open && "line-clamp-3",
      )}
    >
      {highlight ? <Snippet text={highlight} /> : message}
      {tags.length > 0 && (
        <span className="text-muted-foreground"> [{tags.join(", ")}]</span>
      )}
    </span>
  )
  if (!long) return body
  return (
    <button
      type="button"
      onClick={() => setOpen((o) => !o)}
      aria-expanded={open}
      className="block w-full cursor-pointer text-left"
      title={open ? "Collapse" : "Expand"}
    >
      {body}
    </button>
  )
}

function Snippet({ text }: { text: string }) {
  return (
    <>
      {text.split(MARK).map((part, i) =>
        i % 2 === 1 ? (
          <mark key={i} className="fts-mark">
            {part}
          </mark>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </>
  )
}

export default function Logs(p: Props) {
  const { environment, window, range } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const timeParams =
    window === "custom"
      ? { from: range?.from, to: range?.to }
      : { window: window }
  const cursorTimeParams = range
    ? { from: range.from, to: range.to }
    : timeParams
  const visit = (q: string) =>
    router.visit(
      R.applicationEnvironmentLogsPath(a, e, {
        ...timeParams,
        q: q || undefined,
      }),
      {
        only: ["logs", "pagination", "highlights", "counts", "q"],
        preserveState: true,
        preserveScroll: true,
        reset: ["logs", "highlights"],
      },
    )
  const logsPath = (cursor?: string) =>
    R.applicationEnvironmentLogsPath(a, e, {
      ...cursorTimeParams,
      q: p.q || undefined,
      cursor,
      limit: p.pagination.limit,
    })
  const currentLevel = parseFilter(p.q).fields.level
  const setLevel = (level: string | undefined) => {
    const parsed = parseFilter(p.q)
    const fields = { ...parsed.fields }
    if (level) fields.level = level
    else delete fields.level
    visit(serializeFilter({ text: parsed.text, fields }))
  }
  return (
    <EnvLayout title="Logs">
      <PageHeader
        title="Logs"
        description="Rails.logger lines and Rails.event structured events, linked to the request or job that wrote them."
        actions={<SavedViewsMenu page="logs" />}
      />
      <div className="-mx-3 [scrollbar-width:none] overflow-x-auto px-3 md:mx-0 md:px-0 [&::-webkit-scrollbar]:hidden">
        <Segmented className="w-max">
          <SegmentedItem
            active={!currentLevel}
            onClick={() => setLevel(undefined)}
          >
            All
          </SegmentedItem>
          {["debug", "info", "warn", "error", "fatal", "event"].map((l) => (
            <SegmentedItem
              key={l}
              active={currentLevel === l}
              onClick={() => setLevel(l)}
              className="gap-1.5"
            >
              {l}
              <span className="opacity-60">{count(p.counts[l] ?? 0)}</span>
            </SegmentedItem>
          ))}
        </Segmented>
      </div>
      <FilterBar
        value={p.q}
        fields={[
          { key: "after", label: "After" },
          { key: "before", label: "Before" },
          { key: "user", label: "User" },
          { key: "deploy", label: "Deploy" },
          {
            key: "level",
            label: "Level",
            options: [
              "debug",
              "info",
              "warn",
              "error",
              "fatal",
              "event",
              "unknown",
            ],
          },
          {
            key: "kind",
            label: "Execution kind",
            options: ["request", "job", "scheduled_task", "command"],
          },
          { key: "source", label: "Source" },
          { key: "tenant", label: "Tenant" },
        ]}
        onChange={visit}
        placeholder="level:error kind:job source:app/jobs/sync_job.rb:12"
      />
      <div className="text-muted-foreground flex flex-wrap items-baseline gap-x-3 gap-y-1 text-xs">
        <span className="font-mono tabular-nums">
          {count(p.logs.length)} {p.logs.length === 1 ? "line" : "lines"}
        </span>
        <span>
          Full-text search: quotes for phrases, -word to exclude, prefixes match
        </span>
      </div>
      <DataTable
        rows={p.logs}
        rowKey={(l) => l.id}
        empty={
          <EmptyState
            icon={FileText}
            title="No log lines match"
            signal="caution"
            description="Log lines are captured from your app's Rails logger."
          />
        }
        columns={[
          {
            key: "when",
            header: "When",
            className: "w-40",
            cell: (l) => (
              <span className="text-xs tabular-nums">
                {when(l.occurred_at)}
              </span>
            ),
          },
          {
            key: "lvl",
            header: "Level",
            cell: (l) => <LevelBadge level={l.level} />,
          },
          {
            key: "msg",
            header: "Message",
            grow: true,
            className: "whitespace-normal",
            cell: (l) => (
              <LogMessage
                message={l.message}
                highlight={p.highlights[l.id]}
                tags={l.tags}
              />
            ),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (l) =>
              l.execution_id ? (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={R.applicationEnvironmentRequestPath(
                    a,
                    e,
                    l.execution_id,
                  )}
                >
                  {l.execution_preview}
                </Link>
              ) : null,
          },
          {
            key: "t",
            hideOnMobile: true,
            header: "Tenant",
            cell: (l) =>
              l.tenant ? (
                <button
                  className="font-mono text-xs hover:underline"
                  onClick={() => {
                    const parsed = parseFilter(p.q)
                    visit(
                      serializeFilter({
                        text: parsed.text,
                        fields: { ...parsed.fields, tenant: l.tenant! },
                      }),
                    )
                  }}
                >
                  {l.tenant}
                </button>
              ) : null,
          },
        ]}
      />
      <CursorLoadMore
        meta={p.pagination}
        href={logsPath}
        only={["logs", "pagination", "highlights"]}
      />
    </EnvLayout>
  )
}
