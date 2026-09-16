import { useTicker } from "@/hooks/use-ticker"
import { cn } from "@/lib/utils"

function isFresh(lastSeenAt: string | null, thresholdMs: number): boolean {
  if (lastSeenAt === null) return false
  return Date.now() - new Date(lastSeenAt).getTime() < thresholdMs
}

const UNLIT = "bg-neutral-400/15"

// A three-aspect signal head standing in for the usual status dot, lamps
// in their real order: stop on top, caution in the middle, clear at the
// bottom. Fresh telemetry lights the bottom lamp green and pings it; stale
// lights the middle one amber; nothing yet leaves all three unlit. `erroring`
// lights the top lamp red instead, for an environment that is reporting
// but reporting failures. Same colour vocabulary as the empty-state signal
// and the status badges.
export function LiveDot({
  lastSeenAt,
  thresholdMs = 60_000,
  erroring = false,
  className,
}: {
  lastSeenAt: string | null
  thresholdMs?: number
  erroring?: boolean
  className?: string
}) {
  useTicker()
  const fresh = isFresh(lastSeenAt, thresholdMs)
  const state =
    lastSeenAt === null
      ? "none"
      : erroring
        ? "stop"
        : fresh
          ? "clear"
          : "caution"

  return (
    <span
      className={cn(
        "border-foreground/30 bg-background/60 inline-flex w-2.5 shrink-0 flex-col items-center justify-between rounded-full border px-px py-[3px]",
        className,
      )}
      style={{ height: 24 }}
    >
      <span className="relative inline-flex size-1.5">
        {state === "stop" && (
          <span className="bg-danger absolute inline-flex h-full w-full animate-ping rounded-full opacity-75" />
        )}
        <span
          className={cn(
            "relative inline-flex size-1.5 rounded-full transition-colors duration-300",
            state === "stop" ? "bg-danger" : UNLIT,
          )}
        />
      </span>
      <span
        className={cn(
          "inline-flex size-1.5 rounded-full transition-colors duration-300",
          state === "caution" ? "bg-warning" : UNLIT,
        )}
      />
      <span className="relative inline-flex size-1.5">
        {state === "clear" && (
          <span className="bg-live absolute inline-flex h-full w-full animate-ping rounded-full opacity-75" />
        )}
        <span
          className={cn(
            "relative inline-flex size-1.5 rounded-full transition-colors duration-300",
            state === "clear" ? "bg-live" : UNLIT,
          )}
        />
      </span>
    </span>
  )
}
