import { Link, router, usePage } from "@inertiajs/react"
import { ChevronDown, ChevronRight } from "lucide-react"
import { useState } from "react"

import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { JsonViewer } from "@/components/railwatch/json-viewer"
import { PageHeader } from "@/components/railwatch/page-header"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import EnvLayout from "@/layouts/env-layout"
import { parseFilter, serializeFilter } from "@/lib/filter"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface AlertRow {
  id: number
  event: string
  status: string
  sent_at: string | null
  error: string | null
  payload: Record<string, unknown>
  created_at: string
  integration: { kind: string; name: string }
  issue: { id: number; key: string; title: string } | null
}
interface Props {
  alerts: AlertRow[]
  q: string
  statuses: string[]
}

export default function AlertsIndex(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const [expanded, setExpanded] = useState<number | null>(null)
  const visit = (q: string) => {
    const path = environment
      ? R.applicationEnvironmentAlertsPath(
          environment.application_id,
          environment.id,
          { q: q || undefined },
        )
      : R.alertsPath({ q: q || undefined })
    router.visit(path, { preserveState: true, preserveScroll: true })
  }
  const retry = (id: number) =>
    router.post(R.retryAlertPath(id), {}, { preserveScroll: true })

  // "Did anything fail to deliver?" is the question this page exists to
  // answer after an incident, so it gets a button rather than a token the
  // reader has to know how to type.
  const parsed = parseFilter(p.q)
  const failedOnly = parsed.fields.status === "failed"
  const toggleFailed = () => {
    const fields = { ...parsed.fields }
    if (failedOnly) delete fields.status
    else fields.status = "failed"
    visit(serializeFilter({ text: parsed.text, fields }))
  }

  return (
    <EnvLayout title="Alerts" crumbs={[{ title: "Alerts", href: "#" }]}>
      <PageHeader
        withWindow={false}
        title="Alerts"
        description="Fired alerts across your integrations, newest first."
      />
      <div className="flex flex-wrap items-center gap-2">
        <FilterBar
          value={p.q}
          fields={[
            {
              key: "event",
              label: "Event",
              options: ["new_issue", "regressed_issue", "threshold", "quota"],
            },
            { key: "status", label: "Status", options: p.statuses },
          ]}
          onChange={visit}
          placeholder="event:new_issue status:failed"
        />
        <Button
          size="sm"
          variant={failedOnly ? "default" : "outline"}
          className="h-8"
          onClick={toggleFailed}
        >
          Failed only
        </Button>
      </div>
      {p.alerts.length === 0 ? (
        <EmptyState title="No alerts have fired." />
      ) : (
        <div className="divide-y rounded-md border">
          {p.alerts.map((a) => {
            const isOpen = expanded === a.id
            return (
              <div key={a.id} className="p-3">
                <button
                  type="button"
                  className="flex w-full flex-wrap items-center gap-3 text-left text-sm"
                  onClick={() => setExpanded(isOpen ? null : a.id)}
                >
                  {isOpen ? (
                    <ChevronDown className="text-muted-foreground size-4 shrink-0" />
                  ) : (
                    <ChevronRight className="text-muted-foreground size-4 shrink-0" />
                  )}
                  <span className="font-mono text-xs">{a.event}</span>
                  <span className="text-muted-foreground text-xs">
                    {a.integration.name} ({a.integration.kind})
                  </span>
                  {a.issue && (
                    <Link
                      href={R.issuePath(a.issue.id)}
                      onClick={(e) => e.stopPropagation()}
                      className="text-xs hover:underline"
                    >
                      <span className="font-mono font-semibold">
                        {a.issue.key}
                      </span>{" "}
                      <span className="text-muted-foreground">
                        {a.issue.title}
                      </span>
                    </Link>
                  )}
                  <span className="ml-auto flex items-center gap-2">
                    <Badge
                      variant={
                        a.status === "failed" ? "destructive" : "outline"
                      }
                      className="capitalize"
                      title={a.error ?? undefined}
                    >
                      {a.status}
                    </Badge>
                    <RelativeTime
                      iso={a.sent_at ?? a.created_at}
                      className="text-muted-foreground text-xs"
                    />
                    {a.status === "failed" && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={(e) => {
                          e.stopPropagation()
                          retry(a.id)
                        }}
                      >
                        Retry
                      </Button>
                    )}
                  </span>
                </button>
                {isOpen && (
                  <div className="mt-3 space-y-2 pl-7">
                    {a.error && (
                      <p className="text-destructive text-xs">{a.error}</p>
                    )}
                    <JsonViewer data={a.payload} />
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </EnvLayout>
  )
}
