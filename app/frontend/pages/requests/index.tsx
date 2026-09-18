import { Link, router, usePage } from "@inertiajs/react"
import { Activity } from "lucide-react"

import { ChartHoverProvider } from "@/components/railwatch/chart-hover"
import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { PercentilePicker } from "@/components/railwatch/percentile-picker"
import { SavedViewsMenu } from "@/components/railwatch/saved-views"
import { SortHeader } from "@/components/railwatch/sort-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { usePercentile } from "@/hooks/use-percentile"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, pct } from "@/lib/format"
import * as R from "@/routes"
import type { DeployMarker, GroupRow, SeriesPoint, SharedProps } from "@/types"

interface Props {
  routes: GroupRow[]
  series: SeriesPoint[]
  deploys: DeployMarker[]
  sort: string
  dir: string
  q: string
}

export default function Requests(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const { percentile } = usePercentile()
  const a = environment!.application_id
  const e = environment!.id

  const visit = (params: Record<string, string | undefined>) =>
    router.visit(
      R.applicationEnvironmentRequestsPath(a, e, {
        window,
        sort: p.sort,
        dir: p.dir,
        q: p.q || undefined,
        ...params,
      }),
      { preserveState: true },
    )

  const sortBy = (field: string) =>
    visit({
      sort: field,
      dir: p.sort === field && p.dir === "desc" ? "asc" : "desc",
    })

  const routeHref = (x: GroupRow) =>
    R.routeApplicationEnvironmentRequestsPath(a, e, x.group_hash, { window })

  return (
    <EnvLayout title="Requests">
      <ChartHoverProvider>
        <PageHeader
          title="Requests"
          description="Every route your app served, with error rates and percentiles."
          actions={
            <>
              <SavedViewsMenu page="requests" />
              <PercentilePicker />
            </>
          }
        />
        <FilterBar
          value={p.q}
          fields={[
            {
              key: "method",
              label: "Method",
              options: ["GET", "POST", "PUT", "PATCH", "DELETE"],
            },
            {
              key: "status",
              label: "Status",
              options: ["2xx", "3xx", "4xx", "5xx"],
            },
            { key: "route", label: "Route" },
          ]}
          onChange={(q) => visit({ q: q || undefined })}
          placeholder="method:GET status:5xx route:/widgets"
        />
        <div className="grid gap-4 lg:grid-cols-2">
          <VolumePanel label="Requests" data={p.series} deploys={p.deploys} />
          <DurationPanel
            label="Latency"
            data={p.series}
            deploys={p.deploys}
            percentile={percentile}
          />
        </div>
        <DataTable
          rows={p.routes}
          rowKey={(x) => x.group_hash}
          empty={
            <EmptyState
              icon={Activity}
              title="No requests in this window"
              description="HTTP requests to your app appear here as they're reported."
            />
          }
          hoverKey={(x) => x.group_hash}
          keyboardNav={{
            onOpen: (x, opts) =>
              opts?.newTab
                ? globalThis.window.open(routeHref(x), "_blank")
                : router.visit(routeHref(x)),
          }}
          columns={[
            {
              key: "name",
              header: "Route",
              grow: true,
              cell: (x) => (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={routeHref(x)}
                  title={x.name}
                >
                  {x.name}
                </Link>
              ),
            },
            {
              key: "trend",
              hideOnMobile: true,
              header: "Trend",
              cell: (x) => (
                <SparklineCell data={x.sparkline} hoverKey={x.group_hash} />
              ),
            },
            {
              key: "ok",
              hideOnMobile: true,
              header: "2xx",
              align: "right",
              cell: (x) => count(x.count - x.errors - x.client_errors),
            },
            {
              key: "4xx",
              hideOnMobile: true,
              header: "4xx",
              align: "right",
              cell: (x) => count(x.client_errors),
            },
            {
              key: "5xx",
              header: (
                <SortHeader
                  label="5xx"
                  active={p.sort === "errors"}
                  dir={p.dir === "asc" ? "asc" : "desc"}
                  onClick={() => sortBy("errors")}
                />
              ),
              align: "right",
              cell: (x) => (
                <span className={x.errors ? "text-destructive" : ""}>
                  {count(x.errors)}
                </span>
              ),
            },
            {
              key: "total",
              header: (
                <SortHeader
                  label="Total"
                  active={p.sort === "count"}
                  dir={p.dir === "asc" ? "asc" : "desc"}
                  onClick={() => sortBy("count")}
                />
              ),
              align: "right",
              cell: (x) => count(x.count),
            },
            {
              key: "err",
              hideOnMobile: true,
              header: "Error %",
              align: "right",
              cell: (x) => pct(x.errors, x.count),
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
              cell: (x) => ms(x.avg),
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
              cell: (x) => (
                <span className="font-semibold">{ms(x[percentile])}</span>
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
              cell: (x) => ms(x.max),
            },
          ]}
        />
      </ChartHoverProvider>
    </EnvLayout>
  )
}
