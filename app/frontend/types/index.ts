import type { LucideIcon } from "lucide-react"

export interface Auth {
  user: User
  session: Pick<Session, "id" | "recently_authenticated">
}

export interface BreadcrumbItem {
  title: string
  href: string
}

export interface NavItem {
  title: string
  href: string
  icon?: LucideIcon | null
  isActive?: boolean
}

export interface FlashData {
  alert?: string
  warning?: string
  notice?: string
}

export interface AccountSummary {
  id: number
  name: string
  slug: string
  plan: string
}

export interface EnvironmentSummary {
  id: number
  name: string
  slug: string
  last_seen_at: string | null
  paused: boolean
}

export interface ApplicationSummary {
  id: number
  name: string
  slug: string
  issue_prefix: string
  environments: EnvironmentSummary[]
}

export interface EnvironmentContext {
  id: number
  name: string
  slug: string
  application_id: number
  application_name: string
  issue_prefix: string
  last_seen_at: string | null
  paused: boolean
  token_prefix: string
  repository_url: string | null
  default_branch: string
}

export type Window = "1h" | "6h" | "24h" | "7d" | "30d" | "custom"

export interface WindowRange {
  from: string
  to: string
}

export type TelemetryTimeParams =
  | { window: Exclude<Window, "custom">; from?: never; to?: never }
  | { window?: never; from: string; to: string }

export interface CursorMeta {
  limit: number
  next_cursor: string | null
  has_more: boolean
}

// Chart bucket width; the server offers the subset that fits the window.
export type Step = "1m" | "5m" | "15m" | "1h" | "6h" | "1d"

export interface SharedProps {
  auth: Auth
  account: AccountSummary | null
  accounts: { id: number; name: string }[]
  applications: ApplicationSummary[]
  environment?: EnvironmentContext
  telemetry_freshness?: {
    received_at: string | null
    aggregated_at?: string | null
    processing_lag_seconds: number | null
  }
  window?: Window
  range?: WindowRange
  step?: Step
  steps?: Step[]
  flash: FlashData
  google_oauth: boolean
  embedded?: boolean
  saved_views?: SavedView[]
  [key: string]: unknown
}

export interface User {
  id: number
  name: string
  email: string
  provider: string | null
  avatar?: string
  verified: boolean
  editor: string
  editor_root: string | null
  created_at: string
  updated_at: string
  [key: string]: unknown
}

export interface Session {
  id: string
  user_agent: string
  ip_address: string
  created_at: string
  recently_authenticated: boolean
}

// Telemetry shapes shared by pages

export type Percentile = "p50" | "p95" | "p99"

export interface SeriesPoint {
  t: string
  count: number
  errors: number
  client_errors: number
  avg: number | null
  p50: number | null
  p95: number | null
  p99: number | null
}

export interface GroupRow {
  group_hash: string
  name: string
  count: number
  errors: number
  client_errors: number
  avg: number
  p50: number
  p95: number
  p99: number
  max: number
  sparkline: number[]
}

export interface Summary {
  count: number
  errors: number
  client_errors: number
  avg: number
  p50: number
  p95: number
  p99: number
  max: number
}

export interface SummaryWithDelta {
  current: Summary
  previous: Summary
}

// Release health: crash-free rates are null, not 0, when there were no
// sessions (or no users) to divide by.
export interface ReleaseHealthSummary {
  sessions: number
  users: number
  crash_free_sessions: number | null
  crash_free_users: number | null
  errored: number | null
  avg_duration_ms: number | null
}

export interface SessionStatusPoint {
  t: string
  sessions: number
  ok: number
  errored: number
  crashed: number
}

export interface DeployMarker {
  deploy: string
  ref: string
  at: string
}

export interface IssueRow {
  id: number
  key: string
  title: string
  kind: "exception" | "performance"
  status: "open" | "resolved" | "ignored" | "merged"
  priority: "low" | "normal" | "high" | "urgent"
  culprit?: string | null
  occurrences: number
  affected_users: number
  first_seen_at?: string
  last_seen_at: string
  assignee?: { id: number; name: string } | null
  fingerprint_source?: string | null
  source?: string | null
  application?: { id: number; name: string }
  environment?: { id: number; name: string }
}

export interface ExecutionRow {
  execution_id: string
  name: string
  kind?: string
  status?: number | null
  outcome?: string | null
  duration: number
  occurred_at: string
  user_ref?: string | null
  tenant?: string | null
  exception_preview?: string | null
  inertia_component?: string | null
  queries?: number
  deploy?: string | null
}

export interface Frame {
  file: string
  line: number
  function: string
  in_app: boolean
  code?: Record<string, string>
}

export interface ExceptionDetail {
  id: number
  class_name: string
  message: string
  handled: boolean
  severity?: string
  source?: string
  file?: string | null
  line?: number | null
  frames: Frame[]
  cause?: { class: string; message: string } | null
  locals?: Record<string, string> | null
  context?: string | null
  occurred_at?: string
  execution_id?: string | null
  execution_source?: string | null
  execution_preview?: string | null
  deploy?: string | null
  group_hash?: string
}

export interface TimelineEntry {
  type: string
  id: number
  offset: number
  duration: number | null
  label: string
  stage: string | null
  sql?: string | null
  source?: string | null
  detail?: Record<string, string | number | boolean | null>
}

// A named filter on one environment page, shared through every env page's
// props. `url` is built server-side from the page's route helper.
export interface SavedView {
  id: number
  name: string
  page: string
  query: string | null
  window: string | null
  params: Record<string, string>
  pinned: boolean
  shared: boolean
  mine: boolean
  url: string
}
