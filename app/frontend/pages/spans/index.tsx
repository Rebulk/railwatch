import { Link, router, usePage } from "@inertiajs/react"
import { Braces } from "lucide-react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SortHeader } from "@/components/railwatch/sort-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { usePercentile } from "@/hooks/use-percentile"
import EnvLayout from "@/layouts/env-layout"
import { count, ms } from "@/lib/format"
import * as R from "@/routes"
import type {
  GroupRow,
  SeriesPoint,
  SharedProps,
  SummaryWithDelta,
} from "@/types"

interface Props {
  spans: GroupRow[]
  series: SeriesPoint[]
  summary: SummaryWithDelta
  sort: string
  dir: string
  q: string
}

export default function Spans(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id
  const current = p.summary.current

  const sortBy = (field: string) =>
    router.visit(
      R.applicationEnvironmentSpansPath(a, e, {
        window,
        q: p.q || undefined,
        sort: field,
        dir: p.sort === field && p.dir === "desc" ? "asc" : "desc",
      }),
      { preserveState: true },
    )

  const spanHref = (groupHash: string) =>
    R.applicationEnvironmentSpanPath(a, e, groupHash, { window })
  const openSpan = (groupHash: string, opts?: { newTab?: boolean }) =>
    opts?.newTab
      ? globalThis.window.open(spanHref(groupHash), "_blank")
      : router.visit(spanHref(groupHash))

  return (
    <EnvLayout title="Spans">
      <PageHeader
        title="Spans"
        description="Custom spans your app recorded with Railwatch.span, grouped by name."
        actions={<PercentilePicker />}
      />
      <StatStrip>
        <Stat
          label="Spans"
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
          label={percentile}
          value={ms(current[percentile] / 1000, 2)}
          hint={`avg ${ms(current.avg / 1000, 2)}`}
        />
        <Stat label="Max" value={ms(current.max / 1000, 2)} />
      </StatStrip>
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel
          legend="outcome"
          label="Spans"
          seriesLabel="Spans"
          data={p.series}
        />
        <DurationPanel
          label="Duration"
          data={p.series}
          percentile={percentile}
        />
      </div>
      <FilterBar
        value={p.q}
        fields={[
          { key: "name", label: "Name" },
          { key: "status", label: "Status", options: ["failed"] },
        ]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentSpansPath(a, e, {
              window,
              q: q || undefined,
              sort: p.sort,
              dir: p.dir,
            }),
            { preserveState: true },
          )
        }
        placeholder="name:geocode status:failed"
      />
      <DataTable
        rows={p.spans}
        rowKey={(s) => s.group_hash}
        empty={
          <EmptyState
            icon={Braces}
            title="No spans in this window"
            description="Wrap any code in Railwatch.span('name') { } and it shows up here."
          />
        }
        hoverKey={(s) => s.group_hash}
        keyboardNav={{ onOpen: (s, opts) => openSpan(s.group_hash, opts) }}
        columns={[
          {
            key: "name",
            header: "Span",
            grow: true,
            cell: (s) => (
              <Link
                href={spanHref(s.group_hash)}
                className="truncate font-mono text-xs hover:underline"
              >
                {s.name}
              </Link>
            ),
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (s) => (
              <SparklineCell data={s.sparkline} hoverKey={s.group_hash} />
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
            cell: (s) => count(s.count),
          },
          {
            key: "failed",
            header: (
              <SortHeader
                label="Failed"
                active={p.sort === "errors"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("errors")}
              />
            ),
            align: "right",
            cell: (s) => (
              <span className={s.errors ? "text-danger font-semibold" : ""}>
                {count(s.errors)}
              </span>
            ),
          },
          {
            key: "p50",
            hideOnMobile: true,
            header: (
              <SortHeader
                label="p50"
                active={p.sort === "p50"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("p50")}
              />
            ),
            align: "right",
            cell: (s) => ms(s.p50, 2),
          },
          {
            key: "p95",
            header: (
              <SortHeader
                label="p95"
                active={p.sort === "p95"}
                dir={p.dir === "asc" ? "asc" : "desc"}
                onClick={() => sortBy("p95")}
              />
            ),
            align: "right",
            cell: (s) => <span className="font-semibold">{ms(s.p95, 2)}</span>,
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
            cell: (s) => ms(s.max, 2),
          },
        ]}
      />
    </EnvLayout>
  )
}
