import { ArrowDown, ArrowUp } from "lucide-react"
import type { ReactNode } from "react"

import {
  DIGIT_ROLL_ENABLED,
  DigitRoll,
} from "@/components/railwatch/digit-roll"
import { useIsLive } from "@/hooks/use-live"
import { useReducedMotion } from "@/hooks/use-reduced-motion"
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

// A metric a page is happy to see move: the raw number, and the formatter
// that turns it into what the cell reads. Passing this instead of `value` is
// how a page opts into the digit roll, which is deliberately the wrong way
// round from a prop that opts out -- a page that says nothing gets no
// motion, so a new incident page (issues, executions, traces) cannot inherit
// it by accident.
export interface RollingValue {
  value: number
  format: (value: number) => string
}

// The rolling digits are decoration, so they are hidden from assistive tech
// and the number itself sits beside them in one plain text node. Not an
// aria-live region: a value that changes every few seconds read aloud all
// day is not an improvement, and fast live regions misbehave across screen
// readers anyway. A metric that genuinely needs announcing wants its own
// debounced role="status" saying what happened, not the number.
//
// Four gates stand between a rolling number and motion on the screen, and
// all of them have to be open: the global switch, the page having opted in
// at all (this component only renders for `roll`), live updates actually
// flowing, and the user not having asked for less motion. Live off, paused,
// disconnected, or reduced motion each mean an instant swap -- which is
// also WCAG 2.2.2's pause/stop mechanism: the live toggle in the page
// header stops the motion, not just the data.
function RollingStatValue({ value, format }: RollingValue) {
  const live = useIsLive()
  const reducedMotion = useReducedMotion()
  const formatted = format(value)
  const animate = DIGIT_ROLL_ENABLED && live && !reducedMotion
  return (
    <>
      <span aria-hidden="true">
        {animate ? <DigitRoll value={value} format={format} /> : formatted}
      </span>
      <span className="sr-only">{formatted}</span>
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
  roll,
  hint,
  tone,
  delta,
  deltaCaption,
  card = false,
  className,
}: {
  label: string
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
  // A pre-formatted value, or a `roll` the digits of which may animate --
  // one or the other, never both.
} & (
  { value: ReactNode; roll?: never } | { value?: never; roll: RollingValue }
)) {
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
          {roll ? <RollingStatValue {...roll} /> : value}
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
