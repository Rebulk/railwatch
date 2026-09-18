import { ArrowDown, ArrowUp } from "lucide-react"
import type { ReactNode } from "react"

import { cn } from "@/lib/utils"

function Delta({
  current,
  previous,
  goodDirection,
  caption,
}: {
  current: number
  previous: number
  goodDirection: "up" | "down"
  caption?: ReactNode
}) {
  if (!previous) return null
  const change = ((current - previous) / previous) * 100
  if (change === 0) return null
  const direction = change > 0 ? "up" : "down"
  const good = direction === goodDirection
  const Icon = direction === "up" ? ArrowUp : ArrowDown
  return (
    <>
      <span
        className={cn(
          "inline-flex items-center gap-0.5 font-mono text-xs tabular-nums",
          good ? "text-live" : "text-destructive",
        )}
      >
        <Icon className="size-3" />
        {Math.abs(change).toFixed(1)}%
      </span>
      {caption && (
        <span className="text-muted-foreground text-[11px]">{caption}</span>
      )}
    </>
  )
}

// One metric. Nightwatch-style: a small uppercase mono label, a large
// tabular number, and an optional sub-line. Renders as a cell, not a card,
// so a row of them reads as one strip (see StatStrip); pass `card` to get
// the standalone bordered version.
export function Stat({
  label,
  value,
  hint,
  tone,
  delta,
  deltaCaption,
  card = false,
  className,
}: {
  label: string
  value: ReactNode
  hint?: ReactNode
  tone?: "default" | "destructive" | "warning" | "success"
  delta?: {
    current: number
    previous: number
    goodDirection: "up" | "down"
  }
  // e.g. "vs previous 24 hours" — shown next to the delta so it's clear what
  // period the percentage compares against.
  deltaCaption?: ReactNode
  card?: boolean
  className?: string
}) {
  return (
    <div
      className={cn(
        "flex min-w-0 flex-col gap-1 px-4 py-3",
        card && "bg-card rounded-lg border",
        className,
      )}
    >
      <div className="label-caps truncate">{label}</div>
      <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <div
          className={cn(
            "text-xl font-semibold tracking-tight tabular-nums sm:text-2xl",
            tone === "destructive" && "text-destructive",
            tone === "warning" && "text-warning",
            tone === "success" && "text-live",
          )}
        >
          {value}
        </div>
        {delta && <Delta {...delta} caption={deltaCaption} />}
      </div>
      {hint && (
        <div className="text-muted-foreground truncate font-mono text-[11px]">
          {hint}
        </div>
      )}
    </div>
  )
}

// A row of Stats sharing one border, divided by hairlines, that wraps to
// two columns on phones. The header strip on every Nightwatch page.
export function StatStrip({
  children,
  className,
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <div
      className={cn(
        "bg-card divide-border grid grid-cols-2 divide-y overflow-hidden rounded-lg border sm:divide-x sm:divide-y-0",
        "[&>*:nth-child(odd)]:border-r sm:[&>*:nth-child(odd)]:border-r-0",
        "[&>*:nth-child(odd):last-child]:col-span-2 [&>*:nth-child(odd):last-child]:border-r-0 sm:[&>*:nth-child(odd):last-child]:col-span-1",
        "sm:auto-cols-fr sm:grid-flow-col",
        className,
      )}
    >
      {children}
    </div>
  )
}
