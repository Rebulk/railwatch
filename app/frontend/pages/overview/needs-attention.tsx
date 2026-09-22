import { Link } from "@inertiajs/react"
import { ListChecks } from "lucide-react"

import { EmptyState } from "@/components/railwatch/empty-state"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { count } from "@/lib/format"
import * as R from "@/routes"

interface HealthItem {
  id: string
  type: "health"
  severity: "critical" | "warning" | "unknown"
  title: string
  detail: string
}

interface IssueItem {
  id: string
  type: "issue"
  issue_id: number
  key: string
  title: string
  kind: "exception" | "performance" | "anomaly"
  priority: string
  regressed: boolean
  occurrences: number
  affected_users: number
  last_seen_at: string
  deploy: string | null
  evidence: {
    metric: string
    unit: "milliseconds" | "percent" | "events_per_minute" | "usd" | "tokens"
    value: number
    limit: number | null
    baseline_mean: number | null
    from: string
    to: string
  } | null
}

export interface Attention {
  open_issue_count: number
  recent_issue_count: number
  health_count: number
  health_status: "ok" | "warning" | "critical" | "unknown"
  checked_at: string
  from: string
  to: string
  items: (HealthItem | IssueItem)[]
}

const metricNames: Record<string, string> = {
  p95: "p95",
  avg: "Average duration",
  max: "Maximum duration",
  error_rate: "Error rate",
  failure_rate: "Failure rate",
  count: "Volume",
  spend: "Spend",
  tokens: "Tokens",
  truncation_rate: "Truncation rate",
}

function measurement(
  value: number,
  unit: NonNullable<IssueItem["evidence"]>["unit"],
) {
  const number = new Intl.NumberFormat(undefined, {
    maximumFractionDigits: 2,
  }).format(value)
  return {
    milliseconds: `${number} ms`,
    percent: `${number}%`,
    events_per_minute: `${number} events/min`,
    usd: `$${number}`,
    tokens: `${number} tokens`,
  }[unit]
}

function Evidence({
  evidence,
}: {
  evidence: NonNullable<IssueItem["evidence"]>
}) {
  return (
    <p className="text-sm">
      {metricNames[evidence.metric]}{" "}
      {measurement(evidence.value, evidence.unit)}
      {evidence.limit !== null &&
        ` · threshold ${measurement(evidence.limit, evidence.unit)}`}
      {evidence.baseline_mean !== null &&
        ` · baseline mean ${measurement(evidence.baseline_mean, evidence.unit)}`}
      <span className="text-muted-foreground">
        {" "}
        · detected <RelativeTime iso={evidence.to} />
      </span>
    </p>
  )
}

export function NeedsAttention({
  attention,
  applicationId,
  environmentId,
}: {
  attention: Attention
  applicationId: number
  environmentId: number
}) {
  const healthPath = R.applicationEnvironmentMonitoringHealthPath(
    applicationId,
    environmentId,
  )
  const shownIssues = attention.items.filter(
    (item) => item.type === "issue",
  ).length
  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2>Needs attention</h2>
        </CardTitle>
        <CardDescription className="col-span-2 sm:col-span-1">
          Monitoring health now, followed by open issues last seen in the
          selected window. Issues are ranked by priority, recorded users, then
          recency.
        </CardDescription>
        <CardAction className="row-span-1 sm:row-span-2">
          <Link href={healthPath} className="text-sm hover:underline">
            Monitoring health
          </Link>
        </CardAction>
      </CardHeader>
      <CardContent>
        {attention.items.length === 0 ? (
          <EmptyState
            icon={ListChecks}
            title="No recorded findings in this window"
            description="No open issues were last seen in this window and current monitoring checks found no problems. Sampling and configured detectors limit coverage."
          />
        ) : (
          <ol className="divide-y">
            {attention.items.map((item) => (
              <li key={item.id} className="py-3 first:pt-0 last:pb-0">
                <article className="flex flex-col gap-1.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge
                      variant={
                        item.type === "health"
                          ? item.severity === "critical"
                            ? "destructive"
                            : "secondary"
                          : item.priority === "urgent"
                            ? "destructive"
                            : "outline"
                      }
                    >
                      {item.type === "health"
                        ? item.severity === "unknown"
                          ? "Evidence unavailable"
                          : `Monitoring · ${item.severity}`
                        : `${item.kind} · ${item.priority}`}
                    </Badge>
                    {item.type === "issue" && item.regressed && (
                      <Badge variant="secondary">
                        Regressed in this window
                      </Badge>
                    )}
                  </div>
                  <h3 className="text-sm font-medium">
                    <Link
                      href={
                        item.type === "health"
                          ? healthPath
                          : R.issuePath(item.issue_id)
                      }
                      className="hover:underline"
                    >
                      {item.type === "issue" && `${item.key} · `}
                      {item.title}
                    </Link>
                  </h3>
                  {item.type === "health" ? (
                    <p className="text-muted-foreground text-sm">
                      {item.detail}
                    </p>
                  ) : (
                    <>
                      {item.evidence && <Evidence evidence={item.evidence} />}
                      <p className="text-muted-foreground text-xs">
                        {count(item.occurrences)}{" "}
                        {item.kind === "exception"
                          ? "recorded occurrences"
                          : "breached evaluation windows"}{" "}
                        over the issue’s lifetime
                        {item.affected_users > 0 &&
                          ` · ${count(item.affected_users)} recorded users over its lifetime`}{" "}
                        · last seen <RelativeTime iso={item.last_seen_at} />
                        {item.deploy && (
                          <>
                            {" "}
                            · recorded release{" "}
                            <span className="font-mono">{item.deploy}</span>
                          </>
                        )}
                      </p>
                    </>
                  )}
                </article>
              </li>
            ))}
          </ol>
        )}
      </CardContent>
      <CardFooter className="flex-wrap gap-x-4 gap-y-1">
        <p className="text-muted-foreground text-xs">
          {shownIssues} of {count(attention.recent_issue_count)} open issues
          last seen in this window
        </p>
        <p className="text-muted-foreground text-xs">
          {count(attention.health_count)} monitoring findings · checked{" "}
          <RelativeTime iso={attention.checked_at} />
        </p>
      </CardFooter>
    </Card>
  )
}
