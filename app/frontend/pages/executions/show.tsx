import { Link, usePage } from "@inertiajs/react"
import { Check, ClipboardCopy, Copy } from "lucide-react"
import { useState } from "react"

import { DataTable } from "@/components/railwatch/data-table"
import { Flamegraph } from "@/components/railwatch/flamegraph"
import { ExceptionCard } from "@/components/railwatch/frames"
import { JsonViewer } from "@/components/railwatch/json-viewer"
import { OriginIdentity } from "@/components/railwatch/origin-identity"
import { PageHeader } from "@/components/railwatch/page-header"
import { SqlBlock } from "@/components/railwatch/sql-block"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { LevelBadge, StatusBadge } from "@/components/railwatch/status-badge"
import { Timeline } from "@/components/railwatch/timeline"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { useClipboard } from "@/hooks/use-clipboard"
import EnvLayout from "@/layouts/env-layout"
import { executionPath } from "@/lib/execution-path"
import { bytes, count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { ExceptionDetail, SharedProps, TimelineEntry } from "@/types"

interface Execution {
  execution_id: string
  kind: string
  name: string
  duration: number
  status: number | null
  outcome: string | null
  method: string | null
  route: string | null
  controller: string | null
  action: string | null
  queue: string | null
  attempt: number | null
  queue_latency: number | null
  queue_time: number | null
  job_id: string | null
  task_key: string | null
  inertia_component: string | null
  occurred_at: string
  deploy: string | null
  server: string | null
  user_ref: string | null
  tenant: string | null
  trace_id: string
  allocations: number | null
  peak_memory: number | null
  exception_preview: string | null
  profiled: boolean
  stages: Record<string, number>
  counters: Record<string, number>
  detail: Record<string, unknown>
}
interface Attachment {
  id: number
  name: string
  content_type: string | null
  bytes: number
  truncated: boolean
  viewable: boolean
  occurred_at: string
}
interface Props {
  execution: Execution
  timeline: TimelineEntry[]
  exceptions: ExceptionDetail[]
  logs: {
    id: number
    level: string
    message: string
    tags: string[]
    occurred_at: string
    stage: string | null
  }[]
  queries: {
    id: number
    sql: string
    duration: number
    source: string | null
    group_hash: string
    row_count: number | null
    stage: string | null
    offset: number
  }[]
  spans: {
    id: number
    name: string
    duration: number | null
    status: string | null
    attributes: Record<string, unknown>
    offset: number
    stage: string | null
    occurred_at: string
  }[]
  profile: {
    id: number
    profiler: string
    mode: string | null
    interval: number | null
    duration: number
    samples: number
    stacks_bytes: number | null
    collapsed: string
    truncated: boolean
  } | null
  attachments: Attachment[]
  enqueued_jobs: {
    id: number
    name: string
    queue: string
    job_id: string
    offset: number
    attempt_execution_id: string | null
    attempt_outcome: string | null
  }[]
  parent: { execution_id: string; kind: string; name: string } | null
  trace: {
    execution_id: string
    kind: string
    name: string
    duration: number
    status: number | null
    outcome: string | null
    occurred_at: string
    parent_id: string | null
    server: string | null
    current: boolean
  }[]
  trace_url: string | null
  issues: {
    id: number
    key: string
    title: string
    status: string
    group_hash: string
  }[]
  person: { ref: string; name: string | null; email: string | null } | null
}

const kindLabel: Record<string, string> = {
  request: "Request",
  job_attempt: "Job attempt",
  scheduled_task: "Scheduled task",
  command: "Command",
  channel_action: "Channel action",
}

// Tiny local copy-to-clipboard affordance for an inline id. CopyId doesn't
// exist yet (owned elsewhere), so this stays private to this page.
function CopyId({ value }: { value: string }) {
  const [, copy] = useClipboard()
  const [copied, setCopied] = useState(false)
  return (
    <button
      type="button"
      onClick={() => {
        void (async () => {
          const ok = await copy(value)
          if (ok) {
            setCopied(true)
            setTimeout(() => setCopied(false), 1200)
          }
        })()
      }}
      className="hover:text-foreground text-muted-foreground ml-1 inline-flex align-middle"
      title="Copy"
    >
      {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
    </button>
  )
}

function parseContext(v: unknown): unknown {
  try {
    return JSON.parse(String(v)) as unknown
  } catch {
    return String(v)
  }
}

function markdownReport(p: Props, x: Execution) {
  const lines: string[] = []
  lines.push(`# ${x.name}`)
  lines.push("")
  lines.push(`- status: ${x.status ?? x.outcome ?? "-"}`)
  lines.push(`- duration: ${ms(x.duration)}`)
  lines.push(`- occurred_at: ${x.occurred_at}`)
  lines.push("")
  lines.push("## Stages")
  for (const [k, v] of Object.entries(x.stages)) lines.push(`- ${k}: ${ms(v)}`)
  lines.push("")
  lines.push("## Counters")
  for (const [k, v] of Object.entries(x.counters)) lines.push(`- ${k}: ${v}`)
  if (p.exceptions.length > 0) {
    lines.push("")
    lines.push("## Exceptions")
    for (const ex of p.exceptions) {
      lines.push(`### ${ex.class_name}: ${ex.message}`)
      for (const f of ex.frames.filter((fr) => fr.in_app)) {
        lines.push(`- ${f.file}:${f.line} in \`${f.function}\``)
      }
    }
  }
  const slow = [...p.queries]
    .sort((a, b) => b.duration - a.duration)
    .slice(0, 5)
  if (slow.length > 0) {
    lines.push("")
    lines.push("## Slow queries")
    for (const q of slow) lines.push(`- ${ms(q.duration, 2)} — \`${q.sql}\``)
  }
  return lines.join("\n")
}

export default function ExecutionShow(p: Props) {
  const { environment, range, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const x = p.execution
  const detail = x.detail as Record<string, never>
  const headers = (detail.headers ?? {}) as Record<string, string>
  const inertia = detail.inertia as Record<string, unknown> | undefined
  const [, copyMd] = useClipboard()
  const [mdCopied, setMdCopied] = useState(false)
  return (
    <EnvLayout
      title={x.name}
      crumbs={[
        { title: kindLabel[x.kind] ?? x.kind, href: "#" },
        { title: x.name, href: "#" },
      ]}
    >
      <PageHeader
        withWindow={false}
        title={
          <span className="flex flex-wrap items-center gap-2">
            <StatusBadge status={x.status} outcome={x.outcome} />
            <span className="font-mono">{x.name}</span>
            {x.profiled && (
              <Badge variant="secondary" className="font-mono">
                profiled
              </Badge>
            )}
          </span>
        }
        description={
          <span className="flex flex-wrap gap-x-3 text-xs">
            <span>{when(x.occurred_at)}</span>
            {x.server && <span>server {x.server}</span>}
            {x.deploy && <span>deploy {x.deploy.slice(0, 12)}</span>}
            {x.user_ref && (
              <span className="inline-flex items-center gap-1">
                origin user
                <OriginIdentity
                  applicationId={a}
                  environmentId={e}
                  kind="user"
                  range={range}
                  window={window}
                  user_ref={x.user_ref}
                  tenant={x.tenant}
                  person={
                    p.person && {
                      ref: p.person.ref,
                      name: p.person.name ?? p.person.ref,
                    }
                  }
                />
              </span>
            )}
            {x.tenant && (
              <span className="inline-flex items-center gap-1">
                origin tenant
                <OriginIdentity
                  applicationId={a}
                  environmentId={e}
                  kind="tenant"
                  range={range}
                  window={window}
                  user_ref={x.user_ref}
                  tenant={x.tenant}
                  person={null}
                />
              </span>
            )}
          </span>
        }
        actions={
          <Button
            type="button"
            variant="outline"
            size="sm"
            onClick={() => {
              void (async () => {
                const ok = await copyMd(markdownReport(p, x))
                if (ok) {
                  setMdCopied(true)
                  setTimeout(() => setMdCopied(false), 1200)
                }
              })()
            }}
          >
            {mdCopied ? (
              <Check className="size-3.5" />
            ) : (
              <ClipboardCopy className="size-3.5" />
            )}
            Copy as Markdown
          </Button>
        }
      />
      {p.issues.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {p.issues.map((i) => (
            <Link key={i.id} href={R.issuePath(i.id)}>
              <Badge variant="destructive" className="font-mono">
                {i.key}
              </Badge>
            </Link>
          ))}
        </div>
      )}
      <StatStrip>
        <Stat
          label="Duration"
          value={ms(x.duration)}
          hint={
            x.queue_latency != null
              ? `queued ${ms(x.queue_latency)}`
              : undefined
          }
        />
        <Stat
          label="Queries"
          value={x.counters.queries ?? 0}
          hint={`${x.counters.cached_queries ?? 0} cached · ${x.counters.hydrated_models ?? 0} models`}
        />
        {x.queue_time != null && (
          <Stat label="Queue time" value={ms(x.queue_time)} />
        )}
        <Stat label="Cache" value={x.counters.cache_events ?? 0} />
        <Stat
          label="Outgoing"
          value={x.counters.outgoing_requests ?? 0}
          hint={`${x.counters.jobs_enqueued ?? 0} jobs enqueued · ${x.counters.mail ?? 0} mail`}
        />
        <Stat
          label="Allocations"
          value={count(x.allocations)}
          hint={x.peak_memory ? `RSS ${bytes(x.peak_memory)}` : undefined}
        />
        <Stat
          label="Exceptions"
          value={x.counters.exceptions ?? 0}
          tone={x.counters.exceptions ? "destructive" : undefined}
          hint={
            x.counters.lazy_loads
              ? `${x.counters.lazy_loads} lazy loads`
              : undefined
          }
        />
      </StatStrip>
      {p.trace.length > 1 && (
        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center justify-between gap-2">
              Trace
              {p.trace_url && (
                <Link
                  href={p.trace_url}
                  className="text-primary text-xs font-normal hover:underline"
                >
                  View distributed trace
                </Link>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="flex flex-wrap items-center gap-2 text-xs">
              {p.trace.map((t, i) => {
                const maxDur = Math.max(...p.trace.map((tt) => tt.duration), 1)
                return (
                  <span
                    key={t.execution_id}
                    className="flex items-center gap-2"
                  >
                    {i > 0 && <span className="text-muted-foreground">→</span>}
                    <Link
                      href={executionPath({
                        applicationId: a,
                        environmentId: e,
                        source: t.kind,
                        executionId: t.execution_id,
                      })!}
                      className={
                        t.current
                          ? "bg-muted flex items-center gap-1.5 rounded px-2 py-1 font-semibold"
                          : "hover:bg-muted flex items-center gap-1.5 rounded px-2 py-1"
                      }
                    >
                      <StatusBadge status={t.status} outcome={t.outcome} />{" "}
                      <span className="font-mono">{t.name}</span>
                      <span className="bg-muted-foreground/25 relative h-1.5 w-10 overflow-hidden rounded-full">
                        <span
                          className="bg-primary absolute inset-y-0 left-0 rounded-full"
                          style={{
                            width: `${Math.max(4, (t.duration / maxDur) * 100)}%`,
                          }}
                        />
                      </span>
                      <span className="text-muted-foreground">
                        {ms(t.duration)}
                      </span>
                    </Link>
                  </span>
                )
              })}
            </div>
          </CardContent>
        </Card>
      )}
      {p.exceptions.map((ex) => (
        <Card key={ex.id} className="border-destructive/40">
          <CardHeader>
            <CardTitle>Exception</CardTitle>
          </CardHeader>
          <CardContent>
            <ExceptionCard exception={ex} deploy={p.execution.deploy} />
          </CardContent>
        </Card>
      ))}
      <Card>
        <CardHeader>
          <CardTitle>Timeline</CardTitle>
        </CardHeader>
        <CardContent>
          <Timeline entries={p.timeline} total={x.duration} stages={x.stages} />
        </CardContent>
      </Card>
      {p.spans.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Spans</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.spans}
              rowKey={(s) => s.id}
              columns={[
                {
                  key: "off",
                  header: "+ms",
                  align: "right",
                  cell: (s) => s.offset.toFixed(1),
                },
                {
                  key: "name",
                  header: "Span",
                  cell: (s) => (
                    <span className="font-mono text-xs">{s.name}</span>
                  ),
                },
                {
                  key: "status",
                  header: "Status",
                  cell: (s) => <StatusBadge outcome={s.status} />,
                },
                {
                  key: "attrs",
                  header: "Attributes",
                  cell: (s) => (
                    <span className="flex flex-wrap gap-1">
                      {Object.entries(s.attributes).map(([key, value]) => (
                        <span
                          key={key}
                          className="bg-muted rounded-sm px-1.5 font-mono text-[10px]"
                        >
                          {key}={String(value)}
                        </span>
                      ))}
                    </span>
                  ),
                },
                {
                  key: "dur",
                  header: "Duration",
                  align: "right",
                  cell: (s) => ms(s.duration, 2),
                },
              ]}
            />
          </CardContent>
        </Card>
      )}
      {p.profile && (
        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center justify-between gap-2">
              Profile
              <Link
                href={R.applicationEnvironmentProfilePath(a, e, p.profile.id)}
                className="text-primary text-xs font-normal hover:underline"
              >
                Open full profile
              </Link>
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            <p className="text-muted-foreground font-mono text-[11px]">
              {p.profile.profiler}
              {p.profile.mode ? ` · ${p.profile.mode}` : ""} ·{" "}
              {count(p.profile.samples)} samples · {ms(p.profile.duration)}
              {p.profile.truncated && " · truncated for this page"}
            </p>
            <Flamegraph collapsed={p.profile.collapsed} />
          </CardContent>
        </Card>
      )}
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
                  key: "type",
                  hideOnMobile: true,
                  header: "Type",
                  cell: (f) => (
                    <span className="text-muted-foreground font-mono text-xs">
                      {f.content_type ?? "–"}
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
                            a,
                            e,
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
                          a,
                          e,
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
      <Tabs defaultValue="queries">
        <TabsList>
          <TabsTrigger value="queries">
            Queries ({p.queries.length})
          </TabsTrigger>
          <TabsTrigger value="logs">Logs ({p.logs.length})</TabsTrigger>
          <TabsTrigger value="jobs">
            Enqueued jobs ({p.enqueued_jobs.length})
          </TabsTrigger>
          <TabsTrigger value="request">Details</TabsTrigger>
        </TabsList>
        <TabsContent value="queries">
          <DataTable
            rows={p.queries}
            rowKey={(q) => q.id}
            empty="No queries."
            columns={[
              {
                key: "off",
                header: "+ms",
                align: "right",
                cell: (q) => q.offset.toFixed(1),
              },
              {
                key: "sql",
                header: "SQL",
                cell: (q) => (
                  <Link
                    href={R.applicationEnvironmentQueryPath(a, e, q.group_hash)}
                  >
                    <SqlBlock sql={q.sql} className="hover:underline" />
                  </Link>
                ),
              },
              {
                key: "rows",
                header: "Rows",
                align: "right",
                cell: (q) => q.row_count ?? "–",
              },
              {
                key: "src",
                header: "Source",
                cell: (q) => (
                  <span className="text-muted-foreground font-mono text-xs">
                    {q.source ?? ""}
                  </span>
                ),
              },
              {
                key: "dur",
                header: "Duration",
                align: "right",
                cell: (q) => ms(q.duration, 2),
              },
            ]}
          />
        </TabsContent>
        <TabsContent value="logs">
          <DataTable
            rows={p.logs}
            rowKey={(l) => l.id}
            empty="No logs."
            columns={[
              {
                key: "lvl",
                header: "Level",
                cell: (l) => <LevelBadge level={l.level} />,
              },
              {
                key: "msg",
                header: "Message",
                cell: (l) => (
                  <span className="font-mono text-xs whitespace-pre-wrap">
                    {l.message}
                  </span>
                ),
              },
              { key: "tags", header: "Tags", cell: (l) => l.tags.join(" ") },
              {
                key: "stage",
                header: "Stage",
                cell: (l) => (
                  <span className="text-muted-foreground text-xs">
                    {l.stage ?? ""}
                  </span>
                ),
              },
            ]}
          />
        </TabsContent>
        <TabsContent value="jobs">
          <DataTable
            rows={p.enqueued_jobs}
            rowKey={(j) => j.id}
            empty="No jobs enqueued."
            columns={[
              {
                key: "name",
                header: "Job",
                cell: (j) => (
                  <span className="font-mono text-xs">{j.name}</span>
                ),
              },
              { key: "queue", header: "Queue", cell: (j) => j.queue },
              {
                key: "id",
                header: "Job id",
                cell: (j) => (
                  <span className="font-mono text-xs">{j.job_id}</span>
                ),
              },
              {
                key: "attempt",
                header: "Attempt",
                cell: (j) =>
                  j.attempt_execution_id ? (
                    <Link
                      className="hover:underline"
                      href={R.applicationEnvironmentJobPath(
                        a,
                        e,
                        j.attempt_execution_id,
                      )}
                    >
                      <StatusBadge outcome={j.attempt_outcome} />
                    </Link>
                  ) : (
                    <span className="text-muted-foreground text-xs">
                      not seen yet
                    </span>
                  ),
              },
            ]}
          />
        </TabsContent>
        <TabsContent value="request">
          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>Execution</CardTitle>
              </CardHeader>
              <CardContent>
                <dl className="grid gap-y-1 text-xs sm:grid-cols-[10rem_1fr]">
                  {Object.entries({
                    kind: x.kind,
                    trace_id: x.trace_id,
                    execution_id: x.execution_id,
                    controller: x.controller && `${x.controller}#${x.action}`,
                    route: x.route,
                    url: detail.url,
                    ip: detail.ip,
                    format: detail.format,
                    queue: x.queue,
                    attempt: x.attempt,
                    job_id: x.job_id,
                    task_key: x.task_key,
                    schedule: detail.schedule,
                    inertia_component: x.inertia_component,
                    redirect_to: detail.redirect_to,
                    halted_callback: detail.halted_callback,
                    view_runtime: detail.view_runtime,
                    db_runtime: detail.db_runtime,
                    user_agent: detail.user_agent,
                    arguments: Array.isArray(detail.arguments_preview)
                      ? (detail.arguments_preview as string[]).join(", ")
                      : undefined,
                  })
                    .filter(
                      ([, v]) => v !== null && v !== undefined && v !== "",
                    )
                    .map(([k, v]) => (
                      <div key={k} className="contents">
                        <dt className="text-muted-foreground">{k}</dt>
                        <dd className="font-mono break-all">
                          {String(v)}
                          {(k === "trace_id" || k === "execution_id") && (
                            <CopyId value={String(v)} />
                          )}
                        </dd>
                      </div>
                    ))}
                </dl>
                {inertia && (
                  <div className="mt-3">
                    <JsonViewer data={inertia} />
                  </div>
                )}
                {detail.context && detail.context !== "{}" && (
                  <div className="mt-3">
                    <JsonViewer data={parseContext(detail.context)} />
                  </div>
                )}
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle>Headers</CardTitle>
              </CardHeader>
              <CardContent>
                <dl className="grid gap-y-1 text-xs sm:grid-cols-[12rem_1fr]">
                  {Object.entries(headers).map(([k, v]) => (
                    <div key={k} className="contents">
                      <dt className="text-muted-foreground font-mono">{k}</dt>
                      <dd className="font-mono break-all">{v}</dd>
                    </div>
                  ))}
                </dl>
                {detail.payload != null && (
                  <div className="mt-3">
                    <JsonViewer data={detail.payload} />
                  </div>
                )}
              </CardContent>
            </Card>
          </div>
        </TabsContent>
      </Tabs>
    </EnvLayout>
  )
}
