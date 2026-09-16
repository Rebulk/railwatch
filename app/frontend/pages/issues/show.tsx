import { Form, Head, Link, router } from "@inertiajs/react"
import { Check, ClipboardCopy, GitMerge, Globe, Split } from "lucide-react"
import { useEffect, useState } from "react"
import {
  Bar,
  BarChart,
  CartesianGrid,
  ReferenceLine,
  XAxis,
  YAxis,
} from "recharts"

import { DataTable } from "@/components/railwatch/data-table"
import {
  Breadcrumbs,
  BrowserBreadcrumbs,
  type BrowserCrumb,
  ExceptionCard,
} from "@/components/railwatch/frames"
import { JsonViewer } from "@/components/railwatch/json-viewer"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { SourceLink } from "@/components/railwatch/source-link"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { IssueStatusBadge } from "@/components/railwatch/status-badge"
import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import {
  type ChartConfig,
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from "@/components/ui/chart"
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import { useClipboard } from "@/hooks/use-clipboard"
import { useInitials } from "@/hooks/use-initials"
import AppLayout from "@/layouts/app-layout"
import { executionPath } from "@/lib/execution-path"
import { ago, bytes, count, when } from "@/lib/format"
import * as R from "@/routes"
import type { ExceptionDetail, IssueRow, TimelineEntry } from "@/types"

const dailyConfig = {
  count: { label: "Occurrences", color: "var(--chart-5)" },
} satisfies ChartConfig

const detectionConfig = {
  value: { label: "Measured value", color: "var(--chart-2)" },
} satisfies ChartConfig

const groupingHints: Record<string, string> = {
  report: "Fingerprint passed to Railwatch.report.",
  error: "Fingerprint from the error's own #railwatch_fingerprint.",
  resolver: "Fingerprint from the app's Railwatch.fingerprint block.",
  default:
    "Railwatch's default: exception class, top in-app frame, and the message with its variable data removed.",
}

interface Occurrence {
  id: number
  message: string
  handled: boolean
  occurred_at: string
  execution_id: string | null
  execution_source: string | null
  execution_preview: string | null
  user_ref: string | null
  tenant: string | null
  deploy: string | null
  server: string | null
}
interface DetectionRecord {
  record_type: string
  record_id: number
  group_hash: string
  execution_id: string | null
  execution_source: string | null
  execution_preview: string | null
  name: string
  occurred_at: string
  duration_ms: number
  deploy: string | null
  status?: number | null
  outcome?: string | null
  source?: string | null
  connection?: string | null
  role?: string | null
  drilldown: DetectionDrilldown | null
}
interface DetectionDrilldown {
  kind: string
  execution_id?: string | null
  group_hash?: string | null
}

// Queries drill into their group; everything else is an execution, so reuse
// the shared execution-path helper (which accepts both the "job" child wire
// name and the "job_attempt" parent kind) rather than a second copy of it.
function detectionPath(
  issue: Props["issue"],
  drilldown: DetectionDrilldown | null,
): string | null {
  if (!drilldown) return null
  if (drilldown.kind === "query") {
    return drilldown.group_hash
      ? R.applicationEnvironmentQueryPath(
          issue.application.id,
          issue.environment.id,
          drilldown.group_hash,
        )
      : null
  }
  return executionPath({
    applicationId: issue.application.id,
    environmentId: issue.environment.id,
    source: drilldown.kind,
    executionId: drilldown.execution_id,
  })
}
interface DetectionDetail {
  kind: "performance" | "anomaly"
  available: boolean
  message?: string
  telemetry_type?: string
  telemetry_group_hash?: string
  target?: string
  metric?: string
  unit?: string
  count_label: string
  breached_windows: number
  event_count?: number
  window?: { from: string; to: string; minutes: number }
  measurement?: { value?: number; limit?: number }
  baseline?: {
    mean?: number
    stddev?: number
    sigmas?: number
    days?: number
    deviation?: number
  }
  rule?: {
    type?: string
    task_key?: string
    schedule?: string
    last_run?: string
    expected?: string
  }
  representative_records?: DetectionRecord[]
  trend?: { day: string; value: number | null; count: number }[]
  deploy_comparison?: {
    deploy: string
    events: number
    avg_ms: number
    max_ms: number
  }[]
}
interface Props {
  issue: IssueRow & {
    first_seen_at: string
    resolved_at: string | null
    resolved_in_deploy: string | null
    regressed_at: string | null
    sample: Record<string, unknown>
    application: { id: number; name: string }
    environment: { id: number; name: string }
  }
  latest:
    (ExceptionDetail & { ruby_version?: string; rails_version?: string }) | null
  detection: DetectionDetail | null
  occurrences: Occurrence[]
  attachments: {
    id: number
    name: string
    content_type: string | null
    bytes: number
    truncated: boolean
    viewable: boolean
    occurred_at: string
    execution_id: string | null
    execution_preview: string | null
  }[]
  breadcrumbs: TimelineEntry[]
  browser_breadcrumbs: BrowserCrumb[]
  fingerprint: string[]
  fingerprint_source: string | null
  distinct_messages: number
  top_messages: { message: string; count: number }[]
  daily: { day: string; count: number }[]
  by_deploy: Record<string, number>
  by_tenant: Record<string, number>
  comments: { id: number; body: string; user: string; created_at: string }[]
  members: { id: number; name: string }[]
  deploys: { deploy: string; ref: string; at: string }[]
  related_issues: {
    id: number
    key: string
    title: string
    status: string
    environment: { id: number; name: string }
  }[]
  activities: {
    id: number
    kind: string
    data: Record<string, unknown>
    user: { id: number; name: string } | null
    created_at: string
  }[]
  merged_into: { id: number; key: string; title: string } | null
  merged_issues: { id: number; key: string; title: string }[]
  alerts: {
    id: number
    event: string
    status: string
    sent_at: string | null
    error: string | null
    integration: { kind: string; name: string }
  }[]
}

function activitySentence(
  a: Props["activities"][number],
  membersById: Map<number, string>,
) {
  const d = a.data as Record<string, string | number | null>
  switch (a.kind) {
    case "created":
      return "opened this issue"
    case "status":
      return `changed status ${d.from} → ${d.to}`
    case "priority":
      return `changed priority ${d.from} → ${d.to}`
    case "assignee": {
      const from = d.from_id
        ? (membersById.get(Number(d.from_id)) ?? "someone")
        : "unassigned"
      const to = d.to_id
        ? (membersById.get(Number(d.to_id)) ?? "someone")
        : "unassigned"
      return `reassigned ${from} → ${to}`
    }
    case "merge":
      return `merged this issue into ${d.target_key}`
    case "absorbed":
      return `merged ${d.source_key} into this issue (${d.occurrences} events)`
    case "unmerge":
      return "unmerged this issue"
    case "split": {
      const into = Array.isArray(a.data.into) ? (a.data.into as string[]) : []
      return d.from_key
        ? `split ${d.occurrences} events out of ${d.from_key}`
        : `split ${d.occurrences} events by message into ${into.join(", ")}`
    }
    case "regressed":
      return "regressed — a new occurrence reopened this issue"
    case "alert":
      return `sent a "${d.event}" alert via ${d.integration}`
    case "agent":
      return `acted via ${String(d.agent ?? "an AI agent")} (MCP)`
    case "comment":
      return "commented"
    default:
      return String(a.kind)
  }
}

function copyForAiText(p: Props) {
  const i = p.issue
  const lines: string[] = []
  lines.push(`# ${i.key}: ${i.title}`)
  if (i.culprit) lines.push(`Culprit: ${i.culprit}`)
  lines.push(`Environment: ${i.application.name} / ${i.environment.name}`)
  if (p.detection?.available) {
    lines.push("")
    lines.push("## Detector measurement")
    lines.push(
      `${p.detection.metric} for ${p.detection.target}: ${measurement(p.detection.measurement?.value, p.detection.unit)}`,
    )
    if (p.detection.measurement?.limit != null) {
      lines.push(
        `Limit: ${measurement(p.detection.measurement.limit, p.detection.unit)}`,
      )
    }
    if (p.detection.baseline?.mean != null) {
      lines.push(
        `Baseline: ${measurement(p.detection.baseline.mean, p.detection.unit)} (${p.detection.baseline.sigmas}σ)`,
      )
    }
    lines.push(
      `Underlying telemetry: ${p.detection.telemetry_type} ${p.detection.telemetry_group_hash}`,
    )
  }
  if (p.latest) {
    lines.push("")
    lines.push(`## ${p.latest.class_name}`)
    lines.push(p.latest.message)
    const appFrames = p.latest.frames.filter((f) => f.in_app)
    if (appFrames.length > 0) {
      lines.push("")
      lines.push("### Frames")
      for (const f of appFrames) {
        lines.push(`${f.file}:${f.line} in \`${f.function}\``)
        if (f.code) {
          for (const [ln, src] of Object.entries(f.code)) {
            lines.push(`${ln}: ${src}`)
          }
        }
      }
    }
    if (p.latest.context) {
      lines.push("")
      lines.push("### Context")
      lines.push(String(p.latest.context))
    }
  }
  return lines.join("\n")
}

function measurement(value: number | undefined, unit: string | undefined) {
  if (value == null) return "–"
  if (unit === "milliseconds") return `${value.toLocaleString()} ms`
  if (unit === "percent") return `${value.toLocaleString()}%`
  if (unit === "events_per_minute") return `${value.toLocaleString()} / min`
  return value.toLocaleString()
}

function DetectionPanel({
  issue,
  detail,
}: {
  issue: Props["issue"]
  detail: DetectionDetail
}) {
  // Issues opened before typed detection existed still carry their original
  // detector sample. Show it rather than replacing real detail with a notice.
  if (!detail.available) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Detector sample</CardTitle>
        </CardHeader>
        <CardContent>
          <JsonViewer data={issue.sample} />
        </CardContent>
      </Card>
    )
  }
  const records = detail.representative_records ?? []
  const deploys = detail.deploy_comparison ?? []
  const trend = detail.trend ?? []
  const missedSchedule = detail.metric === "missed"
  return (
    <>
      <Card>
        <CardHeader>
          <CardTitle>
            {missedSchedule
              ? "Missed scheduled task"
              : detail.kind === "anomaly"
                ? "Anomaly measurement"
                : "Threshold breach"}
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div>
              <p className="text-muted-foreground text-xs">Target</p>
              <p className="font-mono text-sm">{detail.target}</p>
            </div>
            <div>
              <p className="text-muted-foreground text-xs">
                {missedSchedule ? "Schedule" : "Metric"}
              </p>
              <p className="text-sm">
                {missedSchedule ? detail.rule?.schedule : detail.metric}
              </p>
            </div>
            <div>
              <p className="text-muted-foreground text-xs">
                {missedSchedule ? "Expected" : "Measured"}
              </p>
              <p className="text-sm font-semibold">
                {missedSchedule && detail.rule?.expected
                  ? when(detail.rule.expected)
                  : measurement(detail.measurement?.value, detail.unit)}
              </p>
            </div>
            <div>
              <p className="text-muted-foreground text-xs">
                {missedSchedule
                  ? "Last run"
                  : detail.kind === "anomaly"
                    ? "Baseline"
                    : "Limit"}
              </p>
              <p className="text-sm">
                {missedSchedule && detail.rule?.last_run
                  ? when(detail.rule.last_run)
                  : detail.kind === "anomaly"
                    ? measurement(detail.baseline?.mean, detail.unit)
                    : measurement(detail.measurement?.limit, detail.unit)}
              </p>
            </div>
          </div>
          <p className="text-muted-foreground text-xs">
            {detail.telemetry_type} group {detail.telemetry_group_hash} ·{" "}
            {detail.window?.minutes} minute window
            {detail.baseline?.sigmas != null &&
              ` · ${detail.baseline.sigmas}σ above a ${detail.baseline.days}-day baseline`}
          </p>
        </CardContent>
      </Card>
      {trend.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>{detail.metric} trend (30d)</CardTitle>
          </CardHeader>
          <CardContent>
            <ChartContainer config={detectionConfig} className="h-48 w-full">
              <BarChart data={trend}>
                <CartesianGrid vertical={false} />
                <XAxis
                  dataKey="day"
                  tickLine={false}
                  axisLine={false}
                  minTickGap={24}
                  tickFormatter={(value: string) =>
                    new Date(value).toLocaleDateString(undefined, {
                      month: "short",
                      day: "numeric",
                    })
                  }
                />
                <YAxis width={45} tickLine={false} axisLine={false} />
                <ChartTooltip content={<ChartTooltipContent />} />
                <Bar dataKey="value" fill="var(--color-value)" radius={2} />
              </BarChart>
            </ChartContainer>
          </CardContent>
        </Card>
      )}
      <Card>
        <CardHeader>
          <CardTitle>Representative telemetry</CardTitle>
        </CardHeader>
        <CardContent>
          <DataTable
            rows={records}
            rowKey={(record) => `${record.record_type}-${record.record_id}`}
            empty="Representative raw telemetry has been pruned."
            onRowClick={(record) => {
              const path = detectionPath(issue, record.drilldown)
              if (path) router.visit(path)
            }}
            columns={[
              {
                key: "when",
                header: "When",
                cell: (record) => (
                  <span className="text-xs">{when(record.occurred_at)}</span>
                ),
              },
              {
                key: "record",
                header: "Record",
                className: "max-w-0",
                cell: (record) => (
                  <span className="block truncate font-mono text-xs">
                    {record.name}
                  </span>
                ),
              },
              {
                key: "duration",
                header: "Duration",
                align: "right",
                cell: (record) => `${record.duration_ms.toLocaleString()} ms`,
              },
              {
                key: "deploy",
                header: "Deploy",
                cell: (record) => (
                  <span className="font-mono text-xs">
                    {record.deploy?.slice(0, 10)}
                  </span>
                ),
              },
            ]}
          />
        </CardContent>
      </Card>
      {deploys.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Deploy comparison (30d)</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={deploys}
              rowKey={(deploy) => deploy.deploy}
              columns={[
                {
                  key: "deploy",
                  header: "Deploy",
                  cell: (deploy) => (
                    <span className="font-mono text-xs">
                      {deploy.deploy.slice(0, 12)}
                    </span>
                  ),
                },
                {
                  key: "events",
                  header: "Events",
                  align: "right",
                  cell: (deploy) => count(deploy.events),
                },
                {
                  key: "avg",
                  header: "Avg",
                  align: "right",
                  cell: (deploy) => `${deploy.avg_ms} ms`,
                },
                {
                  key: "max",
                  header: "Max",
                  align: "right",
                  cell: (deploy) => `${deploy.max_ms} ms`,
                },
              ]}
            />
          </CardContent>
        </Card>
      )}
    </>
  )
}

export default function IssueShow(p: Props) {
  const i = p.issue
  const act = (action_name: string, extra: Record<string, unknown> = {}) =>
    router.patch(
      R.issuePath(i.id),
      { action_name, ...extra },
      { preserveScroll: true },
    )
  const [, copyAi] = useClipboard()
  const [aiCopied, setAiCopied] = useState(false)
  const [mergeOpen, setMergeOpen] = useState(false)
  const [mergeQuery, setMergeQuery] = useState("")
  const [mergeCandidates, setMergeCandidates] = useState<
    { id: number; key: string; title: string }[]
  >([])
  const [mergeLoading, setMergeLoading] = useState(false)
  const [mergeError, setMergeError] = useState(false)
  const membersById = new Map(p.members.map((m) => [m.id, m.name]))
  const getInitials = useInitials()
  const occurrencePath = (occurrence: Occurrence) =>
    executionPath({
      applicationId: i.application.id,
      environmentId: i.environment.id,
      source: occurrence.execution_source,
      executionId: occurrence.execution_id,
    })
  const latestPath = p.latest
    ? executionPath({
        applicationId: i.application.id,
        environmentId: i.environment.id,
        source: p.latest.execution_source,
        executionId: p.latest.execution_id,
      })
    : null

  useEffect(() => {
    if (!mergeOpen) return

    const controller = new AbortController()
    const timeout = window.setTimeout(() => {
      setMergeLoading(true)
      setMergeError(false)
      fetch(R.mergeCandidatesIssuePath(i.id, { q: mergeQuery }), {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal: controller.signal,
      })
        .then((response) => {
          if (!response.ok) throw new Error(`HTTP ${response.status}`)
          return response.json() as Promise<{
            issues: { id: number; key: string; title: string }[]
          }>
        })
        .then(({ issues }) => setMergeCandidates(issues))
        .catch(() => {
          if (controller.signal.aborted) return
          setMergeCandidates([])
          setMergeError(true)
        })
        .finally(() => {
          if (!controller.signal.aborted) setMergeLoading(false)
        })
    }, 150)

    return () => {
      window.clearTimeout(timeout)
      controller.abort()
    }
  }, [i.id, mergeOpen, mergeQuery])

  return (
    <AppLayout
      breadcrumbs={[
        { title: "Issues", href: R.issuesPath() },
        { title: i.key, href: R.issuePath(i.id) },
      ]}
    >
      <Head title={`${i.key} ${i.title}`} />
      <div className="flex flex-1 flex-col gap-4 p-3 md:gap-5 md:px-6 md:pt-2 md:pb-6">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-mono text-sm font-semibold">{i.key}</span>
              <IssueStatusBadge status={i.status} />
              <Badge variant="outline">{i.kind}</Badge>
              {i.source === "browser" && (
                <Badge variant="outline" className="gap-1">
                  <Globe className="size-3" />
                  browser
                </Badge>
              )}
              <span className="text-muted-foreground text-xs">
                {i.application.name} · {i.environment.name}
              </span>
            </div>
            <h1 className="mt-1 text-lg font-semibold break-words">
              {i.title}
            </h1>
            {i.culprit && (
              <div className="text-muted-foreground">
                <SourceLink
                  location={i.culprit}
                  deploy={i.sample.deploy as string | null}
                />
              </div>
            )}
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Select
              value={i.priority}
              onValueChange={(v) => act("priority", { priority: v })}
            >
              <SelectTrigger className="w-28">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {["low", "normal", "high", "urgent"].map((x) => (
                  <SelectItem key={x} value={x}>
                    {x}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select
              value={i.assignee ? String(i.assignee.id) : "none"}
              onValueChange={(v) =>
                act("assign", { assignee_id: v === "none" ? null : v })
              }
            >
              <SelectTrigger className="w-40">
                <SelectValue placeholder="Assign" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="none">Unassigned</SelectItem>
                {p.members.map((m) => (
                  <SelectItem key={m.id} value={String(m.id)}>
                    {m.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {i.status === "merged" ? (
              <Button
                size="sm"
                variant="outline"
                onClick={() => act("unmerge")}
              >
                Unmerge
              </Button>
            ) : i.status === "open" ? (
              <>
                <Button size="sm" onClick={() => act("resolve")}>
                  Resolve
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => act("ignore")}
                >
                  Ignore
                </Button>
              </>
            ) : (
              <Button size="sm" variant="outline" onClick={() => act("reopen")}>
                Reopen
              </Button>
            )}
            {i.status !== "merged" && (
              <Button
                size="sm"
                variant="outline"
                onClick={() => setMergeOpen(true)}
              >
                <GitMerge data-icon="inline-start" />
                Merge into…
              </Button>
            )}
            <Button
              size="sm"
              variant="outline"
              onClick={() => {
                void (async () => {
                  const ok = await copyAi(copyForAiText(p))
                  if (ok) {
                    setAiCopied(true)
                    setTimeout(() => setAiCopied(false), 1200)
                  }
                })()
              }}
            >
              {aiCopied ? (
                <Check className="size-3.5" />
              ) : (
                <ClipboardCopy className="size-3.5" />
              )}
              Copy for AI
            </Button>
          </div>
        </div>
        {p.merged_into && (
          <div className="bg-muted flex flex-wrap items-center justify-between gap-2 rounded-md border px-4 py-3 text-sm">
            <span>
              Merged into{" "}
              <Link
                href={R.issuePath(p.merged_into.id)}
                className="font-mono font-semibold underline"
              >
                {p.merged_into.key}
              </Link>{" "}
              <span className="text-muted-foreground">
                {p.merged_into.title}
              </span>
            </span>
            <Button size="sm" variant="outline" onClick={() => act("unmerge")}>
              Unmerge
            </Button>
          </div>
        )}
        <CommandDialog
          open={mergeOpen}
          onOpenChange={(open) => {
            setMergeOpen(open)
            if (!open) {
              setMergeQuery("")
              setMergeCandidates([])
              setMergeError(false)
            }
          }}
          title="Merge into…"
          description="Search issues to merge this one into"
        >
          <CommandInput
            placeholder="Search issues by key or title…"
            value={mergeQuery}
            onValueChange={setMergeQuery}
          />
          <CommandList>
            <CommandEmpty>
              {mergeLoading
                ? "Searching…"
                : mergeError
                  ? "Search failed. Try again."
                  : "No open issues found."}
            </CommandEmpty>
            {mergeCandidates.length > 0 && (
              <CommandGroup>
                {mergeCandidates.map((m) => (
                  <CommandItem
                    key={m.id}
                    value={`${m.key} ${m.title}`}
                    onSelect={() => {
                      act("merge", { target_id: m.id })
                      setMergeOpen(false)
                    }}
                  >
                    <span className="font-mono font-semibold">{m.key}</span>
                    <span className="text-muted-foreground truncate">
                      {m.title}
                    </span>
                  </CommandItem>
                ))}
              </CommandGroup>
            )}
          </CommandList>
        </CommandDialog>
        <StatStrip>
          <Stat
            label={p.detection?.count_label ?? "Events"}
            value={count(p.detection?.breached_windows ?? i.occurrences)}
          />
          <Stat
            label={p.detection ? "Events in measured window" : "Users affected"}
            value={
              p.detection
                ? p.detection.event_count == null
                  ? "–"
                  : count(p.detection.event_count)
                : i.affected_users
            }
          />
          <Stat
            label="First seen"
            value={ago(i.first_seen_at)}
            hint={when(i.first_seen_at)}
          />
          <Stat
            label="Last seen"
            value={ago(i.last_seen_at)}
            hint={when(i.last_seen_at)}
          />
          <Stat
            label={i.regressed_at ? "Regressed" : "Resolved"}
            value={
              i.regressed_at
                ? ago(i.regressed_at)
                : i.resolved_at
                  ? ago(i.resolved_at)
                  : "–"
            }
            hint={
              i.resolved_in_deploy
                ? `in ${i.resolved_in_deploy.slice(0, 12)}`
                : undefined
            }
            tone={i.regressed_at ? "destructive" : undefined}
          />
        </StatStrip>
        <div className="grid gap-6 lg:grid-cols-3">
          <div className="space-y-6 lg:col-span-2">
            {p.detection ? (
              <DetectionPanel issue={i} detail={p.detection} />
            ) : p.latest ? (
              <Card>
                <CardHeader className="flex-row items-center justify-between">
                  <CardTitle>Latest occurrence</CardTitle>
                  {latestPath && (
                    <Link className="text-xs underline" href={latestPath}>
                      Open {p.latest.execution_preview}
                    </Link>
                  )}
                </CardHeader>
                <CardContent>
                  <ExceptionCard
                    exception={p.latest}
                    deploy={p.latest.deploy}
                  />
                  <div className="mt-4 space-y-4">
                    <Breadcrumbs entries={p.breadcrumbs} />
                    <BrowserBreadcrumbs crumbs={p.browser_breadcrumbs} />
                  </div>
                  {(p.latest.ruby_version ?? p.latest.rails_version) && (
                    <p className="text-muted-foreground mt-3 text-xs">
                      Ruby {p.latest.ruby_version} · Rails{" "}
                      {p.latest.rails_version}
                    </p>
                  )}
                </CardContent>
              </Card>
            ) : (
              <Card>
                <CardContent>
                  <JsonViewer data={i.sample} />
                </CardContent>
              </Card>
            )}
            <Card className={p.detection ? "hidden" : undefined}>
              <CardHeader>
                <CardTitle>Occurrences (30d)</CardTitle>
              </CardHeader>
              <CardContent>
                <DataTable
                  rows={p.occurrences}
                  rowKey={(o) => o.id}
                  empty="Raw occurrences have been pruned."
                  onRowClick={(o) => {
                    const path = occurrencePath(o)
                    if (path) router.visit(path)
                  }}
                  columns={[
                    {
                      key: "when",
                      header: "When",
                      cell: (o) => (
                        <span className="text-xs">{when(o.occurred_at)}</span>
                      ),
                    },
                    {
                      key: "in",
                      header: "In",
                      cell: (o) => (
                        <span className="font-mono text-xs">
                          {o.execution_source} {o.execution_preview}
                        </span>
                      ),
                    },
                    {
                      key: "u",
                      header: "User",
                      cell: (o) => (
                        <span className="font-mono text-xs">
                          {o.user_ref ?? ""}
                        </span>
                      ),
                    },
                    {
                      key: "t",
                      header: "Tenant",
                      cell: (o) => (
                        <span className="font-mono text-xs">
                          {o.tenant ?? ""}
                        </span>
                      ),
                    },
                    {
                      key: "d",
                      header: "Deploy",
                      cell: (o) => (
                        <span className="font-mono text-xs">
                          {o.deploy?.slice(0, 10)}
                        </span>
                      ),
                    },
                    {
                      key: "h",
                      header: "",
                      cell: (o) =>
                        o.handled ? (
                          <Badge variant="secondary">handled</Badge>
                        ) : null,
                    },
                  ]}
                />
              </CardContent>
            </Card>
            {p.attachments.length > 0 && (
              <Card>
                <CardHeader>
                  <CardTitle>Attachments</CardTitle>
                </CardHeader>
                <CardContent>
                  <DataTable
                    rows={p.attachments}
                    rowKey={(f) => f.id}
                    columns={[
                      {
                        key: "name",
                        header: "Name",
                        className: "max-w-0",
                        cell: (f) => (
                          <span className="flex items-center gap-1.5">
                            <span className="truncate font-mono text-xs">
                              {f.name}
                            </span>
                            {f.truncated && (
                              <Badge variant="secondary">truncated</Badge>
                            )}
                          </span>
                        ),
                      },
                      {
                        key: "in",
                        header: "In",
                        cell: (f) => (
                          <span className="text-muted-foreground font-mono text-xs">
                            {f.execution_preview ?? "–"}
                          </span>
                        ),
                      },
                      {
                        key: "size",
                        header: "Size",
                        align: "right",
                        cell: (f) => bytes(f.bytes),
                      },
                      {
                        key: "links",
                        header: "",
                        align: "right",
                        cell: (f) => (
                          <span className="flex justify-end gap-3">
                            {f.viewable && (
                              <a
                                className="text-primary hover:underline"
                                href={R.applicationEnvironmentAttachmentPath(
                                  i.application.id,
                                  i.environment.id,
                                  f.id,
                                  { view: 1 },
                                )}
                              >
                                View
                              </a>
                            )}
                            <a
                              className="text-primary hover:underline"
                              href={R.applicationEnvironmentAttachmentPath(
                                i.application.id,
                                i.environment.id,
                                f.id,
                              )}
                            >
                              Download
                            </a>
                          </span>
                        ),
                      },
                    ]}
                  />
                </CardContent>
              </Card>
            )}
          </div>
          <div className="space-y-6">
            <Card className={p.detection ? "hidden" : undefined}>
              <CardHeader>
                <CardTitle>Daily (30d)</CardTitle>
              </CardHeader>
              <CardContent>
                <ChartContainer config={dailyConfig} className="h-40 w-full">
                  <BarChart data={p.daily}>
                    <CartesianGrid vertical={false} />
                    <XAxis
                      dataKey="day"
                      tickLine={false}
                      axisLine={false}
                      minTickGap={24}
                      tickFormatter={(v: string) =>
                        new Date(v).toLocaleDateString(undefined, {
                          month: "short",
                          day: "numeric",
                        })
                      }
                    />
                    <YAxis
                      width={28}
                      tickLine={false}
                      axisLine={false}
                      allowDecimals={false}
                    />
                    <ChartTooltip
                      content={
                        <ChartTooltipContent
                          labelFormatter={(v) => String(v)}
                        />
                      }
                    />
                    <Bar dataKey="count" fill="var(--color-count)" radius={2} />
                    {p.deploys.map((d) => (
                      <ReferenceLine
                        key={d.deploy}
                        x={d.at.slice(0, 10)}
                        stroke="var(--muted-foreground)"
                        strokeDasharray="3 3"
                        label={{
                          value: d.ref,
                          position: "insideTopRight",
                          fontSize: 10,
                        }}
                      />
                    ))}
                  </BarChart>
                </ChartContainer>
              </CardContent>
            </Card>
            <Card className={p.detection ? "hidden" : undefined}>
              <CardHeader>
                <CardTitle>Grouping</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3">
                {p.fingerprint.length > 0 && (
                  <div className="flex flex-wrap gap-1">
                    {p.fingerprint.map((part, index) => (
                      <span
                        key={`${index}-${part}`}
                        className="bg-muted rounded px-1.5 py-0.5 font-mono text-[11px] break-all"
                      >
                        {part}
                      </span>
                    ))}
                  </div>
                )}
                <p className="text-muted-foreground text-xs">
                  {groupingHints[p.fingerprint_source ?? "default"] ??
                    `Fingerprint from ${p.fingerprint_source}.`}
                </p>
                {p.distinct_messages > 1 && (
                  <>
                    <div className="space-y-1">
                      {p.top_messages.map((m) => (
                        <div
                          key={m.message}
                          className="flex items-start justify-between gap-2 text-xs"
                        >
                          <span className="line-clamp-1 font-mono">
                            {m.message}
                          </span>
                          <span className="text-muted-foreground">
                            {count(m.count)}
                          </span>
                        </div>
                      ))}
                    </div>
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => act("split", { by: "message" })}
                    >
                      <Split className="size-3.5" />
                      Split into {p.distinct_messages} issues
                    </Button>
                  </>
                )}
              </CardContent>
            </Card>
            {p.related_issues.length > 0 && (
              <Card>
                <CardHeader>
                  <CardTitle>Related issues</CardTitle>
                </CardHeader>
                <CardContent className="space-y-2">
                  {p.related_issues.map((r) => (
                    <Link
                      key={r.id}
                      href={R.issuePath(r.id)}
                      className="hover:bg-muted/60 -mx-2 flex flex-col rounded px-2 py-1 text-xs"
                    >
                      <span className="flex items-center gap-2">
                        <span className="font-mono font-semibold">{r.key}</span>
                        <IssueStatusBadge status={r.status} />
                      </span>
                      <span className="text-muted-foreground line-clamp-1">
                        {r.title}
                      </span>
                      <span className="text-muted-foreground">
                        {r.environment.name}
                      </span>
                    </Link>
                  ))}
                </CardContent>
              </Card>
            )}
            {p.merged_issues.length > 0 && (
              <Card>
                <CardHeader>
                  <CardTitle>Merged issues</CardTitle>
                </CardHeader>
                <CardContent className="space-y-2">
                  {p.merged_issues.map((m) => (
                    <Link
                      key={m.id}
                      href={R.issuePath(m.id)}
                      className="hover:bg-muted/60 -mx-2 flex flex-col rounded px-2 py-1 text-xs"
                    >
                      <span className="font-mono font-semibold">{m.key}</span>
                      <span className="text-muted-foreground line-clamp-1">
                        {m.title}
                      </span>
                    </Link>
                  ))}
                </CardContent>
              </Card>
            )}
            {p.alerts.length > 0 && (
              <Card>
                <CardHeader>
                  <CardTitle>Alerts</CardTitle>
                </CardHeader>
                <CardContent className="space-y-2">
                  {p.alerts.map((al) => (
                    <div
                      key={al.id}
                      className="flex flex-col gap-0.5 text-xs"
                      title={al.error ?? undefined}
                    >
                      <div className="flex items-center gap-2">
                        <Badge
                          variant={
                            al.status === "failed" ? "destructive" : "outline"
                          }
                          className="capitalize"
                        >
                          {al.status}
                        </Badge>
                        <span>
                          {al.event} via {al.integration.name}
                        </span>
                        <RelativeTime
                          iso={al.sent_at}
                          className="text-muted-foreground"
                        />
                      </div>
                      {al.error && (
                        <span className="text-destructive">{al.error}</span>
                      )}
                    </div>
                  ))}
                </CardContent>
              </Card>
            )}
            <Card>
              <CardHeader>
                <CardTitle>By deploy</CardTitle>
              </CardHeader>
              <CardContent>
                <DataTable
                  rows={Object.entries(p.by_deploy)}
                  rowKey={([d]) => d ?? "none"}
                  columns={[
                    {
                      key: "d",
                      header: "Deploy",
                      cell: ([d]) => (
                        <span className="font-mono text-xs">
                          {d ?? "unknown"}
                        </span>
                      ),
                    },
                    {
                      key: "n",
                      header: "Count",
                      align: "right",
                      cell: ([, n]) => n,
                    },
                  ]}
                />
              </CardContent>
            </Card>
            {Object.keys(p.by_tenant).length > 0 && (
              <Card>
                <CardHeader>
                  <CardTitle>By tenant</CardTitle>
                </CardHeader>
                <CardContent>
                  <DataTable
                    rows={Object.entries(p.by_tenant)}
                    rowKey={([t]) => t}
                    columns={[
                      {
                        key: "t",
                        header: "Tenant",
                        cell: ([t]) => (
                          <span className="font-mono text-xs">{t}</span>
                        ),
                      },
                      {
                        key: "n",
                        header: "Count",
                        align: "right",
                        cell: ([, n]) => n,
                      },
                    ]}
                  />
                </CardContent>
              </Card>
            )}
            <Card>
              <CardHeader>
                <CardTitle>Activity</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3">
                {p.activities.map((a) => {
                  const fromLinear = a.data.source === "linear"
                  const linearAuthor =
                    typeof a.data.author_name === "string"
                      ? a.data.author_name
                      : "Linear"
                  const actorName =
                    a.user?.name ?? (fromLinear ? linearAuthor : "System")
                  return (
                    <div key={a.id} className="flex gap-2 text-sm">
                      <Avatar className="size-6">
                        <AvatarFallback className="text-[10px]">
                          {a.user || fromLinear
                            ? getInitials(actorName)
                            : "sys"}
                        </AvatarFallback>
                      </Avatar>
                      <div className="min-w-0 flex-1">
                        <div className="text-xs">
                          <span className="font-medium">{actorName}</span>{" "}
                          <span className="text-muted-foreground">
                            {activitySentence(a, membersById)}
                          </span>{" "}
                          <RelativeTime
                            iso={a.created_at}
                            className="text-muted-foreground"
                          />
                        </div>
                        {a.kind === "comment" && (
                          <div className="mt-0.5 whitespace-pre-wrap">
                            {String(a.data.body)}
                          </div>
                        )}
                      </div>
                    </div>
                  )
                })}
                <Form
                  method="post"
                  action={R.issueCommentsPath(i.id)}
                  options={{ preserveScroll: true }}
                  resetOnSuccess
                  className="space-y-2"
                >
                  {({ processing }) => (
                    <>
                      <Textarea
                        name="body"
                        placeholder="Add a comment…"
                        required
                        rows={3}
                      />
                      <Button size="sm" disabled={processing}>
                        Comment
                      </Button>
                    </>
                  )}
                </Form>
              </CardContent>
            </Card>
          </div>
        </div>
      </div>
    </AppLayout>
  )
}
