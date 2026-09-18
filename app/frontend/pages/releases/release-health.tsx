import { Stat, StatStrip } from "@/components/railwatch/stat"
import { count, ms } from "@/lib/format"
import type { ReleaseHealthSummary } from "@/types"

// Sentry's own bands: anything under 98% crash-free is a release you roll
// back, 98–99.5% is one you watch.
export function crashFreeTone(rate: number | null) {
  if (rate === null) return "default"
  if (rate >= 99.5) return "success"
  return rate >= 98 ? "warning" : "destructive"
}

// A rate is null, not zero, when there were no sessions to divide by.
export function rate(value: number | null) {
  return value === null ? "–" : `${value.toFixed(2)}%`
}

function delta(current: number | null, previous: number | null | undefined) {
  if (current === null || previous === null || previous === undefined)
    return undefined
  return { current, previous, goodDirection: "up" as const }
}

// The four release-health numbers, shared by the releases index, a release,
// and a deploy. `previous` turns the crash-free stats into deltas.
export function ReleaseHealthStrip({
  health,
  previous,
  deltaCaption,
}: {
  health: ReleaseHealthSummary
  previous?: ReleaseHealthSummary | null
  deltaCaption?: string
}) {
  return (
    <StatStrip>
      <Stat
        label="Crash-free sessions"
        value={rate(health.crash_free_sessions)}
        tone={crashFreeTone(health.crash_free_sessions)}
        delta={delta(health.crash_free_sessions, previous?.crash_free_sessions)}
        deltaCaption={deltaCaption}
        hint={
          health.errored === null
            ? undefined
            : `${health.errored.toFixed(2)}% errored`
        }
      />
      <Stat
        label="Crash-free users"
        value={rate(health.crash_free_users)}
        tone={crashFreeTone(health.crash_free_users)}
        delta={delta(health.crash_free_users, previous?.crash_free_users)}
        deltaCaption={deltaCaption}
      />
      <Stat
        label="Sessions"
        value={count(health.sessions)}
        hint={`${count(health.users)} users`}
      />
      <Stat
        label="Session duration"
        value={ms(health.avg_duration_ms)}
        hint="average"
      />
    </StatStrip>
  )
}
