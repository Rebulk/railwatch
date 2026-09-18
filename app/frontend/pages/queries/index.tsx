import { Link, router, usePage } from "@inertiajs/react"
import {
  CheckIcon,
  ChevronDown,
  ChevronRight,
  CopyIcon,
  Database,
} from "lucide-react"
import { useState } from "react"

import { Sql } from "@/components/railwatch/code"
import { CursorLoadMore } from "@/components/railwatch/cursor-load-more"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SortHeader } from "@/components/railwatch/sort-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useClipboard } from "@/hooks/use-clipboard"
import { usePercentile } from "@/hooks/use-percentile"
import { useWindow } from "@/hooks/use-window"
import EnvLayout from "@/layouts/env-layout"
import { count, ms } from "@/lib/format"
import * as R from "@/routes"
import type {
  CursorMeta,
  GroupRow,
  SharedProps,
  SummaryWithDelta,
} from "@/types"

// Telemetry::NPlusOne#suggestion — the fix Railwatch reads off the repeated
// statement's shape. Null when the SQL isn't a shape a preload can fix.
interface Suggestion {
  kind: string
  parent: string | null
  association: string
  code: string
  explanation: string
}
interface N1 {
  group_hash: string
  occurrences: number
  sql: string
  source: string | null
  max_count: number
  suggestion: Suggestion | null
}
interface Sample {
  id: number
  sql: string
  duration: number
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
  source: string | null
  group_hash: string
}
interface Props {
  queries: GroupRow[]
  n_plus_ones: N1[]
  slowest: Sample[]
  summary: SummaryWithDelta
  sort: string
  dir: string
  q: string
  pagination: CursorMeta
}

const COPIED_RESET_MS = 1500

// The fix for one N+1, revealed under its row. Mono block plus a Copy
// button so the suggested `includes` goes straight into the editor.
function Fix({ suggestion }: { suggestion: Suggestion }) {
  const [, copy] = useClipboard()
  const [copied, setCopied] = useState(false)

  const handleCopy = () => {
    void copy(suggestion.code).then((ok) => {
      if (!ok) return
      setCopied(true)
      window.setTimeout(() => setCopied(false), COPIED_RESET_MS)
    })
  }

  return (
    <div className="border-warning/40 bg-muted/40 mt-2 space-y-2 rounded-lg border p-2">
      <div className="flex items-start justify-between gap-2">
        <pre className="overflow-x-auto font-mono text-xs whitespace-pre-wrap">
          {suggestion.code}
        </pre>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          className="h-6 shrink-0 gap-1 px-1.5 text-xs"
          onClick={(event) => {
            event.stopPropagation()
            handleCopy()
          }}
        >
          {copied ? (
            <CheckIcon className="size-3 text-emerald-500" />
          ) : (
            <CopyIcon className="size-3 opacity-60" />
          )}
          Copy
        </Button>
      </div>
      <p className="text-muted-foreground text-xs whitespace-normal">
        {suggestion.explanation}
      </p>
    </div>
  )
}

export default function Queries(p: Props) {
  const { environment, window, range } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const { label: windowLabel } = useWindow()
  // group_hash of the N+1 row whose suggested fix is expanded, if any.
  const [openFix, setOpenFix] = useState<string | null>(null)
  const a = environment!.application_id
  const e = environment!.id
  const timeParams =
    window === "custom"
      ? { from: range?.from, to: range?.to }
      : { window: window }
  const cursorTimeParams = range
    ? { from: range.from, to: range.to }
    : timeParams
  const samplesPath = (cursor?: string, q = p.q) =>
    R.applicationEnvironmentQueriesPath(a, e, {
      ...(cursor ? cursorTimeParams : timeParams),
      q: q || undefined,
      cursor,
      limit: p.pagination.limit,
      sort: p.sort,
      dir: p.dir,
    })
  const summary = p.summary.current
  const previous = p.summary.previous
  const deltaCaption =
    window === "custom" ? "vs previous period" : `vs previous ${windowLabel}`
  const fixable = p.n_plus_ones.filter((n) => n.suggestion).length

  const toggleFix = (n: N1) => {
    if (!n.suggestion) return
    setOpenFix((current) => (current === n.group_hash ? null : n.group_hash))
  }

  const sortBy = (field: string) =>
    router.visit(
      R.applicationEnvironmentQueriesPath(a, e, {
        ...timeParams,
        q: p.q || undefined,
        sort: field,
        dir: p.sort === field && p.dir === "desc" ? "asc" : "desc",
      }),
      { preserveState: true },
    )

  const queryHref = (groupHash: string) =>
    R.applicationEnvironmentQueryPath(a, e, groupHash, timeParams)
  const openQuery = (groupHash: string, opts?: { newTab?: boolean }) =>
    opts?.newTab
      ? globalThis.window.open(queryHref(groupHash), "_blank")
      : router.visit(queryHref(groupHash))

  return (
    <EnvLayout title="Queries">
      <PageHeader
        title="Queries"
        description="Every SQL shape your app ran, grouped by normalized statement."
        actions={<PercentilePicker />}
      />
      <StatStrip>
        <Stat
          label="Queries"
          value={count(summary.count)}
          delta={{
            current: summary.count,
            previous: previous.count,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="N+1 groups"
          value={count(p.n_plus_ones.length)}
          tone={p.n_plus_ones.length > 0 ? "warning" : undefined}
          hint={
            p.n_plus_ones.length > 0
              ? `${fixable} with a suggested fix`
              : undefined
          }
        />
        <Stat
          label="Avg"
          value={ms(summary.avg / 1000, 2)}
          delta={{
            current: summary.avg,
            previous: previous.avg,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
        <Stat
          label="p95"
          value={ms(summary.p95 / 1000, 2)}
          hint={`p99 ${ms(summary.p99 / 1000, 2)}`}
          delta={{
            current: summary.p95,
            previous: previous.p95,
            goodDirection: "down",
          }}
          deltaCaption={deltaCaption}
        />
      </StatStrip>
      {p.n_plus_ones.length > 0 && (
        <Card className="border-amber-500/40">
          <CardHeader>
            <CardTitle>N+1 queries detected</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.n_plus_ones}
              rowKey={(n) => n.group_hash}
              onRowClick={toggleFix}
              keyboardNav={{
                onOpen: (n, opts) => openQuery(n.group_hash, opts),
              }}
              columns={[
                {
                  key: "sql",
                  header: "Query shape",
                  grow: true,
                  cell: (n) => (
                    <>
                      <Link
                        href={R.applicationEnvironmentQueryPath(
                          a,
                          e,
                          n.group_hash,
                        )}
                      >
                        <Sql className="hover:underline">{n.sql}</Sql>
                      </Link>
                      {openFix === n.group_hash && n.suggestion && (
                        <Fix suggestion={n.suggestion} />
                      )}
                    </>
                  ),
                },
                {
                  key: "fix",
                  header: "Fix",
                  cell: (n) =>
                    n.suggestion ? (
                      <button
                        type="button"
                        aria-expanded={openFix === n.group_hash}
                        aria-label={`Suggested fix: ${n.suggestion.code}`}
                        onClick={(event) => {
                          event.stopPropagation()
                          toggleFix(n)
                        }}
                        className="border-warning/50 text-warning hover:bg-warning/10 inline-flex items-center gap-0.5 rounded-md border py-0.5 pr-1.5 pl-0.5 font-mono text-[11px] uppercase"
                      >
                        {openFix === n.group_hash ? (
                          <ChevronDown className="size-3" />
                        ) : (
                          <ChevronRight className="size-3" />
                        )}
                        Fix
                      </button>
                    ) : null,
                },
                {
                  key: "src",
                  hideOnMobile: true,
                  header: "Source",
                  cell: (n) => (
                    <span className="text-muted-foreground font-mono text-xs">
                      {n.source ?? ""}
                    </span>
                  ),
                },
                {
                  key: "occ",
                  header: "Executions affected",
                  align: "right",
                  cell: (n) => n.occurrences,
                },
                {
                  key: "mx",
                  hideOnMobile: true,
                  header: "Max repeats",
                  align: "right",
                  cell: (n) => n.max_count,
                },
              ]}
            />
          </CardContent>
        </Card>
      )}
      <DataTable
        rows={p.queries}
        rowKey={(q) => q.group_hash}
        empty={
          <EmptyState
            icon={Database}
            title="No queries in this window"
            description="SQL queries executed by your app appear here as they're reported."
          />
        }
        hoverKey={(q) => q.group_hash}
        keyboardNav={{
          onOpen: (q, opts) => openQuery(q.group_hash, opts),
        }}
        columns={[
          {
            key: "sql",
            header: "Query",
            grow: true,
            cell: (q) => (
              <Link href={queryHref(q.group_hash)}>
                <Sql className="hover:underline">{q.name}</Sql>
              </Link>
            ),
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (q) => (
              <SparklineCell data={q.sparkline} hoverKey={q.group_hash} />
            ),
          },
          {
            key: "n",
            header: (
              <SortHeader
                label="Count"
                active={p.sort === "count"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("count")}
              />
            ),
            align: "right",
            cell: (q) => count(q.count),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: (
              <SortHeader
                label="Avg"
                active={p.sort === "avg"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("avg")}
              />
            ),
            align: "right",
            cell: (q) => ms(q.avg, 2),
          },
          {
            key: percentile,
            header: (
              <SortHeader
                label={percentile}
                active={p.sort === percentile}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy(percentile)}
              />
            ),
            align: "right",
            cell: (q) => (
              <span className="font-semibold">{ms(q[percentile], 2)}</span>
            ),
          },
          {
            key: "max",
            hideOnMobile: true,
            header: (
              <SortHeader
                label="Max"
                active={p.sort === "max"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("max")}
              />
            ),
            align: "right",
            cell: (q) => ms(q.max, 2),
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Slowest individual queries</h2>
      <FilterBar
        value={p.q}
        fields={[
          { key: "after", label: "After" },
          { key: "before", label: "Before" },
          { key: "user", label: "User" },
          { key: "tenant", label: "Tenant" },
          { key: "deploy", label: "Deploy" },
          { key: "source", label: "Source" },
          {
            key: "kind",
            label: "Execution kind",
            options: ["request", "job", "scheduled_task", "command"],
          },
          { key: "connection", label: "Connection" },
          { key: "role", label: "Role" },
          { key: "adapter", label: "Adapter" },
        ]}
        onChange={(q) =>
          router.visit(samplesPath(undefined, q), {
            only: ["slowest", "pagination", "q"],
            preserveState: true,
            reset: ["slowest"],
          })
        }
        placeholder="connection:primary role:reading source:app/models"
      />
      <DataTable
        rows={p.slowest}
        rowKey={(s) => s.id}
        keyboardNav={{
          onOpen: (s, opts) => openQuery(s.group_hash, opts),
        }}
        columns={[
          {
            key: "sql",
            header: "SQL",
            grow: true,
            cell: (s) => (
              <Link href={queryHref(s.group_hash)}>
                <Sql className="hover:underline">{s.sql}</Sql>
              </Link>
            ),
          },
          {
            key: "exe",
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
            key: "src",
            hideOnMobile: true,
            header: "Source",
            cell: (s) => (
              <span className="text-muted-foreground font-mono text-xs">
                {s.source ?? ""}
              </span>
            ),
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (s) => ms(s.duration, 2),
          },
        ]}
      />
      <CursorLoadMore
        meta={p.pagination}
        href={samplesPath}
        only={["slowest", "pagination"]}
      />
    </EnvLayout>
  )
}
