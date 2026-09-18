import { usePage } from "@inertiajs/react"

import { badgeVariants } from "@/components/ui/badge"
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip"
import { useLive } from "@/hooks/use-live"
import { useTicker } from "@/hooks/use-ticker"
import { ago } from "@/lib/format"
import { cn } from "@/lib/utils"
import type { SharedProps } from "@/types"

import { LiveDot } from "./live-dot"

// Small pill embedded in every environment page's PageHeader: pulses while
// live ingest events are flowing, click to pause/resume the automatic
// background reloads that keep the page's data fresh.
export function LiveToggle({ environmentId }: { environmentId: number }) {
  useTicker()
  const { environment, telemetry_freshness: freshness } =
    usePage<SharedProps>().props
  const { connected, lastEventAt, lastRefreshedAt, paused, setPaused } =
    useLive(environmentId)
  const lastEventIso =
    lastEventAt != null
      ? new Date(lastEventAt).toISOString()
      : (freshness?.received_at ?? environment?.last_seen_at ?? null)
  const refreshedIso =
    lastRefreshedAt != null ? new Date(lastRefreshedAt).toISOString() : null

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          aria-pressed={paused}
          aria-label={paused ? "Resume live updates" : "Pause live updates"}
          onClick={() => setPaused(!paused)}
          className={cn(
            badgeVariants({ variant: "outline" }),
            "hover:bg-accent h-7 cursor-pointer gap-1.5 rounded-md font-mono text-[11px] tracking-wide uppercase",
          )}
        >
          <LiveDot
            lastSeenAt={connected ? lastEventIso : null}
            thresholdMs={10_000}
          />
          {paused ? "Paused" : connected ? "Live" : "Disconnected"}
        </button>
      </TooltipTrigger>
      <TooltipContent>
        <p>
          {lastEventIso
            ? `Telemetry received ${ago(lastEventIso)}`
            : "No telemetry received yet"}
        </p>
        <p>
          {refreshedIso
            ? `Page refreshed ${ago(refreshedIso)}`
            : "No live refresh yet"}
        </p>
        {freshness?.processing_lag_seconds != null && (
          <p>
            Ingest processing pending:{" "}
            {Math.round(freshness.processing_lag_seconds)}s
          </p>
        )}
        {freshness?.aggregated_at && (
          <p>Charts updated {ago(freshness.aggregated_at)}</p>
        )}
      </TooltipContent>
    </Tooltip>
  )
}
