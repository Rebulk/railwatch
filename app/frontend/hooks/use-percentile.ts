import { router } from "@inertiajs/react"

import type { Percentile } from "@/types"

const PERCENTILES: Percentile[] = ["p50", "p95", "p99"]

// Client-only URL param (?pct=), not inertia_share'd like window: every
// list page reads/writes it the same way the count/p95 sort toggle already
// does with router.visit + preserveState.
export function usePercentile() {
  const url = new URL(globalThis.location.href)
  const raw = url.searchParams.get("pct")
  const percentile: Percentile = PERCENTILES.includes(raw as Percentile)
    ? (raw as Percentile)
    : "p95"

  const set = (value: Percentile) => {
    const next = new URL(globalThis.location.href)
    next.searchParams.set("pct", value)
    router.visit(next.toString(), { preserveScroll: true, preserveState: true })
  }

  return { percentile, set }
}
