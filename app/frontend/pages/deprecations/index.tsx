import { Link, router, usePage } from "@inertiajs/react"
import { useState } from "react"

import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { Sparkline } from "@/components/railwatch/series-chart"
import { Stat } from "@/components/railwatch/stat"
import { Badge } from "@/components/ui/badge"
import { Card, CardContent } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { executionPath } from "@/lib/execution-path"
import { count, when } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Occurrence {
  id: number
  occurred_at: string
  execution_id: string | null
  execution_source: string | null
  execution_preview: string | null
}
interface DeprecationGroup {
  group_hash: string
  message: string
  gem_name: string | null
  horizon: string | null
  source: string | null
  count: number
  first_seen_at: string | null
  last_seen_at: string
  sparkline: number[]
  occurrences: Occurrence[]
}
interface Props {
  deprecations: DeprecationGroup[]
  distinct: number
  total_occurrences: number
  new_this_window: number
  q: string
}

function DeprecationRow({
  d,
  a,
  e,
}: {
  d: DeprecationGroup
  a: number
  e: number
}) {
  const [open, setOpen] = useState(false)
  return (
    <Card>
      <CardContent className="flex flex-col gap-2 pt-4">
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="flex flex-wrap items-start justify-between gap-4 text-left"
        >
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              {d.gem_name && (
                <Badge variant="secondary" className="font-mono">
                  {d.gem_name}
                </Badge>
              )}
              {d.horizon && (
                <Badge variant="outline" className="font-mono">
                  removed in {d.horizon}
                </Badge>
              )}
            </div>
            <p className="mt-1 font-mono text-xs whitespace-pre-wrap">
              {d.message}
            </p>
            {d.source && (
              <p className="text-muted-foreground mt-1 font-mono text-xs">
                {d.source}
              </p>
            )}
          </div>
          <div className="flex shrink-0 items-center gap-4">
            <Sparkline data={d.sparkline} className="h-10 w-32" />
            <div className="text-right">
              <div className="text-lg font-semibold tabular-nums">
                {count(d.count)}
              </div>
              <div className="text-muted-foreground text-xs">occurrences</div>
            </div>
          </div>
        </button>
        <div className="text-muted-foreground flex gap-4 text-xs">
          <span>First seen {when(d.first_seen_at)}</span>
          <span>Last seen {when(d.last_seen_at)}</span>
        </div>
        {open && (
          <div className="mt-2 overflow-hidden rounded-lg border">
            <table className="w-full text-xs">
              <tbody>
                {d.occurrences.map((o) => (
                  <tr key={o.id} className="border-t first:border-t-0">
                    <td className="px-3 py-1.5 tabular-nums">
                      {when(o.occurred_at)}
                    </td>
                    <td className="px-3 py-1.5">
                      {o.execution_id ? (
                        <Link
                          className="font-mono hover:underline"
                          href={executionPath({
                            applicationId: a,
                            environmentId: e,
                            source: o.execution_source,
                            executionId: o.execution_id,
                          })!}
                        >
                          {o.execution_preview}
                        </Link>
                      ) : (
                        <span className="text-muted-foreground">–</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

export default function Deprecations(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id

  return (
    <EnvLayout title="Deprecations">
      <PageHeader
        title="Deprecations"
        description="ActiveSupport::Deprecation warnings, grouped by gem and message."
      />
      <div className="grid grid-cols-3 gap-3">
        <Stat label="Distinct deprecations" value={count(p.distinct)} />
        <Stat label="Total occurrences" value={count(p.total_occurrences)} />
        <Stat label="New this window" value={count(p.new_this_window)} />
      </div>
      <FilterBar
        value={p.q}
        fields={[{ key: "gem", label: "Gem" }]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentDeprecationsPath(a, e, {
              window,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="gem:rails deprecated method"
      />
      {p.deprecations.length === 0 ? (
        <EmptyState title="No deprecations in this window." />
      ) : (
        <div className="flex flex-col gap-3">
          {p.deprecations.map((d) => (
            <DeprecationRow key={d.group_hash} d={d} a={a} e={e} />
          ))}
        </div>
      )}
    </EnvLayout>
  )
}
