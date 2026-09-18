import { cn } from "@/lib/utils"

// busy-out-of-max as a hairline bar plus the raw pair, for thread pools and
// connection pools. Same tone thresholds the Processes stat strip uses:
// amber from 70%, red from 90%.
export function UtilisationBar({
  busy,
  max,
  className,
}: {
  busy: number | null
  max: number | null
  className?: string
}) {
  if (!max) return <span className="text-muted-foreground">–</span>
  const ratio = Math.min(1, (busy ?? 0) / max)
  return (
    <span className={cn("flex items-center gap-1.5", className)}>
      <span
        role="meter"
        aria-label="Utilisation"
        aria-valuenow={busy ?? 0}
        aria-valuemin={0}
        aria-valuemax={max}
        className="bg-muted-foreground/25 relative h-1.5 w-10 shrink-0 overflow-hidden rounded-full"
      >
        <span
          className={cn(
            "absolute inset-y-0 left-0 rounded-full",
            ratio >= 0.9
              ? "bg-danger"
              : ratio >= 0.7
                ? "bg-warning"
                : "bg-live",
          )}
          style={{ width: `${Math.max(4, ratio * 100)}%` }}
        />
      </span>
      <span className="font-mono tabular-nums">
        {busy ?? 0}/{max}
      </span>
    </span>
  )
}
