import { Link, router, usePage } from "@inertiajs/react"

import { VolumePanel } from "@/components/railwatch/chart-panel"
import { CursorLoadMore } from "@/components/railwatch/cursor-load-more"
import { DataTable } from "@/components/railwatch/data-table"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { SavedViewsMenu } from "@/components/railwatch/saved-views"
import { Badge } from "@/components/ui/badge"
import { Card, CardContent } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { executionPath } from "@/lib/execution-path"
import { count, when } from "@/lib/format"
import * as R from "@/routes"
import type { CursorMeta, SeriesPoint, SharedProps } from "@/types"

function HandledBadge({ handled }: { handled: boolean }) {
  return (
    <Badge variant={handled ? "secondary" : "destructive"}>
      {handled ? "handled" : "unhandled"}
    </Badge>
  )
}

function SeverityBadge({ severity }: { severity: string | null }) {
  if (!severity) return null
  const variant =
    severity === "fatal" || severity === "error"
      ? "destructive"
      : severity === "warning"
        ? "secondary"
        : "outline"
  return (
    <Badge variant={variant} className="capitalize">
      {severity}
    </Badge>
  )
}

interface ExceptionRow {
  id: number
  class_name: string
  message: string
  handled: boolean
  severity: string | null
  source: string | null
  file: string | null
  line: number | null
  occurred_at: string
  execution_id: string | null
  execution_source: string | null
  execution_preview: string | null
  user_ref: string | null
  group_hash: string
  issue_id: number | null
  issue_key: string | null
}
interface Props {
  exceptions: ExceptionRow[]
  classes: [string, number][]
  series: SeriesPoint[]
  total: number
  unhandled: number
  pagination: CursorMeta
  q: string
}

export default function Exceptions(p: Props) {
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
  const exceptionsPath = (cursor?: string) =>
    R.applicationEnvironmentExceptionsPath(a, e, {
      ...cursorTimeParams,
      q: p.q || undefined,
      cursor,
      limit: p.pagination.limit,
    })

  return (
    <EnvLayout title="Exceptions">
      <PageHeader
        title="Exceptions"
        description="Every exception raised, handled or not -- distinct from Issues, which group and track these over time."
        actions={<SavedViewsMenu page="exceptions" />}
      />
      <VolumePanel
        legend="exception"
        label="Exceptions"
        seriesLabel="Exceptions"
        data={p.series}
      />
      <div className="grid grid-cols-3 gap-3">
        <Card className="gap-1 py-4">
          <CardContent className="px-4">
            <div className="text-muted-foreground text-xs font-medium tracking-wide uppercase">
              Total
            </div>
            <div className="mt-1 text-2xl font-semibold tabular-nums">
              {count(p.total)}
            </div>
          </CardContent>
        </Card>
        <Card className="gap-1 py-4">
          <CardContent className="px-4">
            <div className="text-muted-foreground text-xs font-medium tracking-wide uppercase">
              Unhandled
            </div>
            <div className="text-destructive mt-1 text-2xl font-semibold tabular-nums">
              {count(p.unhandled)}
            </div>
          </CardContent>
        </Card>
        <Card className="gap-1 py-4">
          <CardContent className="px-4">
            <div className="text-muted-foreground text-xs font-medium tracking-wide uppercase">
              Top classes
            </div>
            <div className="mt-1 flex flex-wrap gap-1">
              {p.classes.slice(0, 5).map(([klass, n]) => (
                <Badge key={klass} variant="outline" className="font-mono">
                  {klass} ({count(n)})
                </Badge>
              ))}
            </div>
          </CardContent>
        </Card>
      </div>
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
          { key: "class", label: "Class" },
          { key: "handled", label: "Handled", options: ["true", "false"] },
          {
            key: "severity",
            label: "Severity",
            options: ["fatal", "error", "warning", "info"],
          },
        ]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentExceptionsPath(a, e, {
              ...timeParams,
              q: q || undefined,
            }),
            {
              only: ["exceptions", "pagination", "q"],
              preserveState: true,
              reset: ["exceptions"],
            },
          )
        }
        placeholder="class:ActiveRecord::RecordNotFound handled:false"
      />
      <DataTable
        rows={p.exceptions}
        rowKey={(x) => x.id}
        empty="No exceptions in this window."
        columns={[
          {
            key: "when",
            header: "When",
            className: "w-40",
            cell: (x) => (
              <span className="text-xs tabular-nums">
                {when(x.occurred_at)}
              </span>
            ),
          },
          {
            key: "class",
            header: "Class",
            grow: true,
            cell: (x) => (
              <div className="flex flex-col gap-0.5">
                {x.issue_key ? (
                  <Link
                    className="font-mono text-xs font-semibold hover:underline"
                    href={R.issuePath(x.issue_id!)}
                  >
                    {x.class_name}
                  </Link>
                ) : (
                  <span className="font-mono text-xs font-semibold">
                    {x.class_name}
                  </span>
                )}
                <span className="text-muted-foreground line-clamp-1 text-xs">
                  {x.message}
                </span>
              </div>
            ),
          },
          {
            key: "handled",
            header: "Handled",
            cell: (x) => <HandledBadge handled={x.handled} />,
          },
          {
            key: "sev",
            hideOnMobile: true,
            header: "Severity",
            cell: (x) => <SeverityBadge severity={x.severity} />,
          },
          {
            key: "source",
            hideOnMobile: true,
            header: "Source",
            cell: (x) => (
              <span className="text-muted-foreground font-mono text-xs">
                {x.source ?? ""}
              </span>
            ),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (x) =>
              x.execution_id ? (
                <Link
                  className="font-mono text-xs hover:underline"
                  href={executionPath({
                    applicationId: a,
                    environmentId: e,
                    source: x.execution_source,
                    executionId: x.execution_id,
                  })!}
                >
                  {x.execution_preview}
                </Link>
              ) : (
                <span className="text-muted-foreground text-xs">–</span>
              ),
          },
          {
            key: "user",
            hideOnMobile: true,
            header: "User",
            cell: (x) => (
              <span className="font-mono text-xs">{x.user_ref ?? ""}</span>
            ),
          },
        ]}
      />
      <CursorLoadMore
        meta={p.pagination}
        href={exceptionsPath}
        only={["exceptions", "pagination"]}
      />
    </EnvLayout>
  )
}
