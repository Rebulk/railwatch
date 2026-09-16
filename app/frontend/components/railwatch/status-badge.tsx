import { Badge } from "@/components/ui/badge"
import { statusTone } from "@/lib/format"
import { cn } from "@/lib/utils"

// The one status vocabulary: grey is fine, amber is a warning (4xx, elevated),
// red is broken (5xx, failed, unhandled, open). Small mono caps like
// Nightwatch's [ALERT] / HANDLED / UNHANDLED chips.
const tones: Record<string, string> = {
  success: "border-live/30 bg-live/10 text-live",
  warning: "border-warning/40 bg-warning/10 text-warning",
  destructive: "border-danger/40 bg-danger/10 text-danger",
  muted: "border-border bg-muted text-muted-foreground",
}

const base = "rounded-sm px-1.5 font-mono text-[10px] tracking-wider uppercase"

export function StatusBadge({
  status,
  outcome,
  label,
}: {
  status?: number | null
  outcome?: string | null
  label?: string
}) {
  const tone = statusTone(status, outcome)
  return (
    <Badge variant="outline" className={cn(base, "tabular-nums", tones[tone])}>
      {label ?? outcome ?? status ?? "–"}
    </Badge>
  )
}

export function LevelBadge({ level }: { level: string }) {
  const tone =
    level === "error" || level === "fatal"
      ? "destructive"
      : level === "warn"
        ? "warning"
        : level === "event"
          ? "success"
          : "muted"
  return (
    <Badge variant="outline" className={cn(base, tones[tone])}>
      {level}
    </Badge>
  )
}

export function IssueStatusBadge({ status }: { status: string }) {
  const tone =
    status === "open"
      ? "destructive"
      : status === "resolved"
        ? "success"
        : "muted"
  return (
    <Badge variant="outline" className={cn(base, tones[tone])}>
      {status}
    </Badge>
  )
}

// Generic tinted chip for kinds and categories (EXCEPTION, REQUEST, JOB…).
export function KindBadge({
  children,
  tone = "muted",
  className,
}: {
  children: React.ReactNode
  tone?: keyof typeof tones
  className?: string
}) {
  return (
    <Badge variant="outline" className={cn(base, tones[tone], className)}>
      {children}
    </Badge>
  )
}
