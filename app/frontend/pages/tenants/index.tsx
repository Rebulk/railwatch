import { Link, router, usePage } from "@inertiajs/react"
import { Building2 } from "lucide-react"

import { ChartHoverProvider } from "@/components/railwatch/chart-hover"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { SortHeader } from "@/components/railwatch/sort-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import EnvLayout from "@/layouts/env-layout"
import { ago, count, ms } from "@/lib/format"
import { tenantPath } from "@/pages/tenants/tenant-path"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

export interface TenantRow {
  tenant: string
  requests: number
  errors: number
  avg: number
  max: number
  p95: number
  jobs: number
  failed_jobs: number
  exceptions: number
  logs: number
  users: number
  last_seen_at: string | null
  sparkline: number[]
}

interface Props {
  tenants: TenantRow[]
  summary: {
    tenants: number
    top_tenant: string | null
    top_share: number
    with_errors: number
    untagged_share: number
  }
  sort: string
  dir: string
  q: string
}

export default function Tenants(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id

  const visit = (params: Record<string, string | undefined>) =>
    router.visit(
      R.applicationEnvironmentTenantsPath(a, e, {
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

  const href = (x: TenantRow) => tenantPath(a, e, x.tenant, { window })

  return (
    <EnvLayout title="Tenants">
      <ChartHoverProvider>
        <PageHeader
          title="Tenants"
          description="Your application's own tenants, aggregated from the tenant tag on every record."
        />
        <StatStrip>
          <Stat label="Tenants active" value={count(p.summary.tenants)} />
          <Stat
            label="Top tenant"
            value={`${p.summary.top_share}%`}
            hint={p.summary.top_tenant ?? "none"}
          />
          <Stat
            label="With 5xx"
            value={count(p.summary.with_errors)}
            tone={p.summary.with_errors ? "destructive" : "success"}
          />
          <Stat
            label="Untagged"
            value={`${p.summary.untagged_share}%`}
            hint="requests with no tenant"
          />
        </StatStrip>
        <FilterBar
          value={p.q}
          fields={[]}
          onChange={(q) => visit({ q: q || undefined })}
          placeholder="Filter tenants"
        />
        <DataTable
          rows={p.tenants}
          rowKey={(x) => x.tenant}
          empty={
            <EmptyState
              icon={Building2}
              title="No tenant-tagged records in this window"
              description="Records carry the tenant from ActiveRecord::Tenanted / TenantRecord.current_tenant, or call Railwatch.context(tenant: org.slug)"
            />
          }
          hoverKey={(x) => x.tenant}
          onRowClick={(x) => router.visit(href(x))}
          keyboardNav={{
            onOpen: (x, opts) =>
              opts?.newTab
                ? globalThis.window.open(href(x), "_blank")
                : router.visit(href(x)),
          }}
          columns={[
            {
              key: "tenant",
              header: "Tenant",
              cell: (x) => (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={href(x)}
                >
                  {x.tenant}
                </Link>
              ),
            },
            {
              key: "trend",
              hideOnMobile: true,
              header: "Trend",
              cell: (x) => (
                <SparklineCell data={x.sparkline} hoverKey={x.tenant} />
              ),
            },
            {
              key: "requests",
              header: (
                <SortHeader
                  label="Requests"
                  active={p.sort === "requests"}
                  dir={p.dir === "asc" ? "asc" : "desc"}
                  onClick={() => sortBy("requests")}
                />
              ),
              align: "right",
              cell: (x) => count(x.requests),
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
              cell: (x) => <span className="font-semibold">{ms(x.p95)}</span>,
            },
            {
              key: "jobs",
              hideOnMobile: true,
              header: "Jobs",
              align: "right",
              cell: (x) => count(x.jobs),
            },
            {
              key: "failed",
              hideOnMobile: true,
              header: "Failed",
              align: "right",
              cell: (x) => (
                <span className={x.failed_jobs ? "text-destructive" : ""}>
                  {count(x.failed_jobs)}
                </span>
              ),
            },
            {
              key: "exceptions",
              hideOnMobile: true,
              header: "Exceptions",
              align: "right",
              cell: (x) => count(x.exceptions),
            },
            {
              key: "users",
              hideOnMobile: true,
              header: (
                <SortHeader
                  label="Users"
                  active={p.sort === "users"}
                  dir={p.dir === "asc" ? "asc" : "desc"}
                  onClick={() => sortBy("users")}
                />
              ),
              align: "right",
              cell: (x) => count(x.users),
            },
            {
              key: "seen",
              header: "Last seen",
              align: "right",
              cell: (x) => ago(x.last_seen_at),
            },
          ]}
        />
      </ChartHoverProvider>
    </EnvLayout>
  )
}
