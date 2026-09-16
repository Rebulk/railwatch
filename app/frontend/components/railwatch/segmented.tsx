import type { ReactNode } from "react"

import { cn } from "@/lib/utils"

// Nightwatch's period bar: a bordered pill holding mono buttons, the selected
// one filled blue. Used for time windows, percentiles, and status tabs so
// every segmented choice in the app looks the same.
export function Segmented({
  children,
  className,
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <div
      className={cn(
        "bg-card flex h-8 shrink-0 items-center gap-px rounded-lg border p-0.5",
        className,
      )}
    >
      {children}
    </div>
  )
}

export function SegmentedItem({
  active,
  onClick,
  children,
  className,
  mono = true,
  disabled,
  "aria-label": ariaLabel,
}: {
  active: boolean
  onClick: () => void
  children: ReactNode
  className?: string
  mono?: boolean
  disabled?: boolean
  "aria-label"?: string
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-pressed={active}
      aria-label={ariaLabel}
      className={cn(
        "flex h-full min-w-8 items-center justify-center gap-1.5 rounded-md border px-2.5 text-xs whitespace-nowrap transition-colors",
        mono && "font-mono uppercase",
        active
          ? "bg-primary border-primary text-primary-foreground"
          : "text-muted-foreground hover:bg-accent hover:text-foreground border-transparent",
        disabled && "cursor-not-allowed opacity-50",
        className,
      )}
    >
      {children}
    </button>
  )
}
