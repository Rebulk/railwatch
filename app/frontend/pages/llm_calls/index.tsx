import { Link, router, usePage } from "@inertiajs/react"
import {
  ChevronDown,
  ChevronRight,
  Paperclip,
  Scissors,
  Sparkles,
} from "lucide-react"
import { Fragment, useState } from "react"

import { DurationPanel, VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import { StatusBadge } from "@/components/railwatch/status-badge"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, pct, usd, when } from "@/lib/format"
import { cn } from "@/lib/utils"
import * as R from "@/routes"
import type { SeriesPoint, SharedProps } from "@/types"

interface ModelRow {
  group_hash: string
  name: string
  count: number
  errors: number
  truncated: number
  with_attachments: number
  input_tokens: number
  output_tokens: number
  cache_read_tokens: number
  cache_write_tokens: number
  cost: number | null
  unpriced: number
  avg: number
  p95: number
  sparkline: number[]
}

interface Recent {
  id: number
  operation: string
  provider: string | null
  model: string | null
  response_model: string | null
  tool_name: string | null
  duration: number
  status: string | null
  error: string | null
  streaming: boolean | null
  message_count: number | null
  tool_count: number | null
  input_tokens: number | null
  output_tokens: number | null
  cache_read_tokens: number | null
  cache_write_tokens: number | null
  thinking_tokens: number | null
  cost: number | null
  cost_reported: boolean | null
  finish_reason: string | null
  provider_request_id: string | null
  tools: string | null
  attachments: number | null
  attachment_types: string | null
  attachment_names: string | null
  tool_call_id: string | null
  params: Record<string, unknown> | null
  workflow_id: string | null
  workflow_name: string | null
  workflow_step_name: string | null
  prompt: string | null
  completion: string | null
  occurred_at: string
  execution_id: string | null
  execution_preview: string | null
}

interface ToolRow {
  group_hash: string
  name: string
  count: number
  errors: number
  avg: number
  p95: number
  max: number
  sparkline: number[]
}

interface Totals {
  count: number
  errors: number
  tool_count: number
  tool_errors: number
  input_tokens: number
  output_tokens: number
  cost: number | null
  unpriced: number
}

interface Props {
  models: ModelRow[]
  tools: ToolRow[]
  recent: Recent[]
  totals: Totals
  series: SeriesPoint[]
  tool_series: SeriesPoint[]
  q: string
}

const NO_MODELS = (
  <EmptyState
    icon={Sparkles}
    title="No model calls in this window"
    description="Chats, embeddings, and other model calls your app makes through RubyLLM appear here, with the request or job that made them."
  />
)

const NO_TOOLS = (
  <EmptyState
    icon={Sparkles}
    title="No tool calls in this window"
    description="Tools your models invoke appear here, timed separately from the calls that asked for them."
  />
)

// Only present when capture_llm_content is on, which is off by default.
// Same shape as the outgoing-request body viewer: the text is already in
// the row, so opening it fetches nothing.
// max_tokens means the answer was cut off mid-sentence. It is a successful
// HTTP call, so nothing else on this page would ever show it.
function FinishReason({ reason }: { reason: string | null }) {
  if (!reason || reason === "stop" || reason === "tool_calls") return null
  const bad = reason === "max_tokens" || reason === "content_filter"
  return (
    <span
      className={cn(
        "ml-2 inline-flex items-center gap-1 text-xs",
        bad ? "text-destructive" : "text-muted-foreground",
      )}
      title={
        reason === "max_tokens"
          ? "The answer was cut off at the output token limit"
          : `Model stopped: ${reason}`
      }
    >
      <Scissors className="size-3" />
      {reason}
    </span>
  )
}

function Attachments({ call }: { call: Recent }) {
  if (!call.attachments) return null
  return (
    <span
      className="text-muted-foreground ml-2 inline-flex items-center gap-1 text-xs"
      title={
        call.attachment_names ??
        `${call.attachments} file(s): ${call.attachment_types}`
      }
    >
      <Paperclip className="size-3" />
      {call.attachment_types ?? call.attachments}
    </span>
  )
}

function Content({ call }: { call: Recent }) {
  const [open, setOpen] = useState(false)
  const { prompt, completion, params, provider_request_id, tools } = call
  const hasDetail =
    prompt !== null ||
    completion !== null ||
    provider_request_id !== null ||
    tools !== null ||
    (params !== null && Object.keys(params).length > 0)
  if (!hasDetail) return <span className="text-muted-foreground">–</span>
  const Chevron = open ? ChevronDown : ChevronRight
  return (
    <div className="flex flex-col items-end gap-1">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1"
      >
        <Chevron className="size-3" />
        Detail
      </button>
      {open && (
        <div className="w-[70vw] max-w-[36rem] space-y-2 text-left">
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 font-mono text-[10px]">
            {provider_request_id && (
              <>
                <dt className="text-muted-foreground">provider id</dt>
                <dd className="break-all">{provider_request_id}</dd>
              </>
            )}
            {tools && (
              <>
                <dt className="text-muted-foreground">tools</dt>
                <dd className="break-all">{tools}</dd>
              </>
            )}
            {params &&
              Object.entries(params).map(([k, v]) => (
                <Fragment key={k}>
                  <dt className="text-muted-foreground">{k}</dt>
                  <dd className="break-all">
                    {typeof v === "string" || typeof v === "number"
                      ? v
                      : JSON.stringify(v)}
                  </dd>
                </Fragment>
              ))}
          </dl>
          {[
            ["Prompt", prompt],
            ["Completion", completion],
          ].map(([label, text]) =>
            text ? (
              <div key={label}>
                <div className="text-muted-foreground text-[10px] tracking-wide uppercase">
                  {label}
                </div>
                <pre className="bg-muted max-h-64 overflow-auto rounded p-2 font-mono text-[10px] break-all whitespace-pre-wrap">
                  {text}
                </pre>
              </div>
            ) : null,
          )}
        </div>
      )}
    </div>
  )
}

// A spend figure that leaves calls out is worse than no figure, so say how
// many it leaves out rather than letting the number pass for the whole bill.
function Spend({ cost, unpriced }: { cost: number | null; unpriced: number }) {
  if (cost === null)
    return unpriced > 0 ? (
      <span className="text-muted-foreground" title="No registry pricing">
        unpriced
      </span>
    ) : (
      <span className="text-muted-foreground" title="Nothing here has a price">
        –
      </span>
    )
  return (
    <span className="font-semibold">
      {usd(cost)}
      {unpriced > 0 && (
        <span
          className="text-muted-foreground ml-1 text-xs font-normal"
          title={`${unpriced} call${unpriced === 1 ? "" : "s"} had no registry pricing and are not in this total`}
        >
          +{count(unpriced)} unpriced
        </span>
      )}
    </span>
  )
}

function Stat({
  label,
  children,
}: {
  label: string
  children: React.ReactNode
}) {
  return (
    <div className="min-w-0">
      <div className="text-muted-foreground text-xs">{label}</div>
      <div className="truncate text-lg">{children}</div>
    </div>
  )
}

export default function LlmCalls(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const href = (r: Recent) =>
    r.execution_id
      ? R.applicationEnvironmentRequestPath(a, e, r.execution_id)
      : null

  return (
    <EnvLayout title="LLM">
      <PageHeader
        title="LLM"
        description="Model calls and tool invocations through RubyLLM, by model and by the request or job that made them."
      />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <Stat label="Model calls">{count(p.totals.count)}</Stat>
        <Stat label="Tool calls">{count(p.totals.tool_count)}</Stat>
        <Stat label="Spend">
          <Spend cost={p.totals.cost} unpriced={p.totals.unpriced} />
        </Stat>
        <Stat label="Tokens in">{count(p.totals.input_tokens)}</Stat>
        <Stat label="Tokens out">{count(p.totals.output_tokens)}</Stat>
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <VolumePanel
          legend="request"
          label="Model calls"
          seriesLabel="Calls"
          data={p.series}
        />
        <DurationPanel label="Model latency" data={p.series} percentile="p95" />
      </div>
      {p.totals.tool_count > 0 && (
        <div className="grid gap-4 lg:grid-cols-2">
          <VolumePanel
            legend="request"
            label="Tool calls"
            seriesLabel="Calls"
            data={p.tool_series}
          />
          <DurationPanel
            label="Tool latency"
            data={p.tool_series}
            percentile="p95"
          />
        </div>
      )}
      <DataTable
        rows={p.models}
        rowKey={(m) => m.group_hash}
        empty={NO_MODELS}
        columns={[
          {
            key: "m",
            header: "Model",
            cell: (m) => <span className="font-mono text-xs">{m.name}</span>,
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (m) => <SparklineCell data={m.sparkline} />,
          },
          {
            key: "n",
            header: "Calls",
            align: "right",
            cell: (m) => count(m.count),
          },
          {
            key: "f",
            hideOnMobile: true,
            header: "Failed",
            align: "right",
            cell: (m) => (
              <span className={m.errors ? "text-destructive" : ""}>
                {pct(m.errors, m.count)}
              </span>
            ),
          },
          {
            key: "cut",
            hideOnMobile: true,
            header: "Cut off",
            align: "right",
            cell: (m) =>
              m.truncated ? (
                <span
                  className="text-destructive"
                  title="Answers stopped at the output token limit"
                >
                  {pct(m.truncated, m.count)}
                </span>
              ) : (
                <span className="text-muted-foreground">–</span>
              ),
          },
          {
            key: "att",
            hideOnMobile: true,
            header: "With files",
            align: "right",
            cell: (m) =>
              m.with_attachments ? (
                count(m.with_attachments)
              ) : (
                <span className="text-muted-foreground">–</span>
              ),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "Tokens in",
            align: "right",
            cell: (m) => count(m.input_tokens),
          },
          {
            key: "out",
            hideOnMobile: true,
            header: "Tokens out",
            align: "right",
            cell: (m) => count(m.output_tokens),
          },
          {
            key: "cached",
            hideOnMobile: true,
            header: "Cached",
            align: "right",
            cell: (m) => count(m.cache_read_tokens),
          },
          {
            key: "p95",
            hideOnMobile: true,
            header: "p95",
            align: "right",
            cell: (m) => ms(m.p95),
          },
          {
            key: "cost",
            header: "Spend",
            align: "right",
            cell: (m) => <Spend cost={m.cost} unpriced={m.unpriced} />,
          },
        ]}
      />
      {p.tools.length > 0 && (
        <>
          <h2 className="text-sm font-semibold">Tools</h2>
          <DataTable
            rows={p.tools}
            rowKey={(t) => t.group_hash}
            empty={NO_TOOLS}
            columns={[
              {
                key: "t",
                header: "Tool",
                cell: (t) => (
                  <span className="font-mono text-xs">{t.name}</span>
                ),
              },
              {
                key: "trend",
                hideOnMobile: true,
                header: "Trend",
                cell: (t) => <SparklineCell data={t.sparkline} />,
              },
              {
                key: "n",
                header: "Calls",
                align: "right",
                cell: (t) => count(t.count),
              },
              {
                key: "f",
                hideOnMobile: true,
                header: "Failed",
                align: "right",
                cell: (t) => (
                  <span className={t.errors ? "text-destructive" : ""}>
                    {pct(t.errors, t.count)}
                  </span>
                ),
              },
              {
                key: "avg",
                hideOnMobile: true,
                header: "Avg",
                align: "right",
                cell: (t) => ms(t.avg),
              },
              {
                key: "p95",
                header: "p95",
                align: "right",
                cell: (t) => <span className="font-semibold">{ms(t.p95)}</span>,
              },
              {
                key: "max",
                hideOnMobile: true,
                header: "Max",
                align: "right",
                cell: (t) => ms(t.max),
              },
            ]}
          />
        </>
      )}
      <h2 className="text-sm font-semibold">Recent</h2>
      <FilterBar
        value={p.q}
        fields={[
          { key: "model", label: "Model" },
          { key: "provider", label: "Provider" },
          {
            key: "operation",
            label: "Operation",
            options: [
              "chat",
              "tool",
              "embedding",
              "image",
              "speech",
              "transcription",
              "moderation",
              "rerank",
              "ocr",
            ],
          },
          { key: "workflow", label: "Workflow" },
          {
            key: "finish",
            label: "Finish",
            options: ["stop", "max_tokens", "tool_calls", "content_filter"],
          },
          {
            key: "attachments",
            label: "Files",
            options: ["any", "image", "pdf", "audio", "video"],
          },
        ]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentLlmCallsPath(a, e, {
              window,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="model:claude-opus-5 operation:chat"
      />
      <DataTable
        rows={p.recent}
        rowKey={(r) => r.id}
        empty={NO_MODELS}
        keyboardNav={{
          onOpen: (r, opts) => {
            const to = href(r)
            if (!to) return
            if (opts?.newTab) globalThis.window.open(to, "_blank")
            else router.visit(to)
          },
        }}
        columns={[
          {
            key: "when",
            header: "When",
            cell: (r) => <span className="text-xs">{when(r.occurred_at)}</span>,
          },
          {
            key: "st",
            header: "Status",
            cell: (r) => (
              <StatusBadge
                status={null}
                label={r.status === "failed" ? "error" : r.operation}
                outcome={r.status === "failed" ? "failed" : undefined}
              />
            ),
          },
          {
            key: "what",
            header: "Call",
            cell: (r) => (
              <span className="font-mono text-xs">
                {r.operation === "tool" ? (
                  r.tool_name
                ) : (
                  <>
                    <span className="text-muted-foreground">{r.provider}/</span>
                    <span className="font-semibold">{r.model}</span>
                  </>
                )}
                {r.error && (
                  <span className="text-destructive ml-2">{r.error}</span>
                )}
                <FinishReason reason={r.finish_reason} />
                <Attachments call={r} />
              </span>
            ),
          },
          {
            key: "wf",
            hideOnMobile: true,
            header: "Workflow",
            cell: (r) =>
              r.workflow_name ? (
                <span className="text-xs">
                  {r.workflow_name}
                  {r.workflow_step_name && (
                    <span className="text-muted-foreground">
                      {" · "}
                      {r.workflow_step_name}
                    </span>
                  )}
                </span>
              ) : null,
          },
          {
            key: "tok",
            hideOnMobile: true,
            header: "Tokens",
            align: "right",
            cell: (r) =>
              r.input_tokens === null && r.output_tokens === null ? (
                <span className="text-muted-foreground">–</span>
              ) : (
                <span className="font-mono text-xs">
                  {count(r.input_tokens ?? 0)} / {count(r.output_tokens ?? 0)}
                </span>
              ),
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (r) => ms(r.duration),
          },
          {
            key: "cost",
            header: "Cost",
            align: "right",
            cell: (r) =>
              r.cost === null && r.operation !== "tool" ? (
                <span
                  className="text-muted-foreground"
                  title="No registry pricing"
                >
                  unpriced
                </span>
              ) : (
                usd(r.cost)
              ),
          },
          {
            key: "in",
            hideOnMobile: true,
            header: "In",
            cell: (r) => {
              const to = href(r)
              return to ? (
                <Link className="font-mono text-xs hover:underline" href={to}>
                  {r.execution_preview}
                </Link>
              ) : null
            },
          },
          {
            key: "content",
            header: "Detail",
            align: "right",
            cell: (r) => <Content call={r} />,
          },
        ]}
      />
    </EnvLayout>
  )
}
