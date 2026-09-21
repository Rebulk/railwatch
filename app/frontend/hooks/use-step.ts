import { router, usePage } from "@inertiajs/react"

import type { SharedProps, Step } from "@/types"

export const STEP_LABELS: Record<Step, string> = {
  "1m": "1 minute",
  "5m": "5 minutes",
  "15m": "15 minutes",
  "1h": "1 hour",
  "6h": "6 hours",
  "1d": "1 day",
}

// The chart bucket width (?step=) and the widths the current window offers,
// both inertia_share'd by EnvironmentScoped like `window` is. Changing the
// window drops the step so the new window draws at its own default.
export function useStep() {
  const { step = "1h", steps = [] } = usePage<SharedProps>().props

  const set = (value: Step) => {
    const url = new URL(globalThis.location.href)
    url.searchParams.set("step", value)
    router.visit(url.toString(), { preserveScroll: true, preserveState: true })
  }

  return { step, steps, set, label: STEP_LABELS[step] ?? step }
}
