import { router, usePage } from "@inertiajs/react"

import type { SharedProps, Window } from "@/types"

export const WINDOWS: { value: Window; label: string }[] = [
  { value: "1h", label: "1 hour" },
  { value: "6h", label: "6 hours" },
  { value: "24h", label: "24 hours" },
  { value: "7d", label: "7 days" },
  { value: "30d", label: "30 days" },
]

function formatRange(from: string, to: string) {
  const fmt: Intl.DateTimeFormatOptions = {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }
  return `${new Date(from).toLocaleString(undefined, fmt)} – ${new Date(to).toLocaleString(undefined, fmt)}`
}

export function useWindow() {
  const { window: current = "24h", range } = usePage<SharedProps>().props

  const set = (value: Window) => {
    const url = new URL(globalThis.location.href)
    url.searchParams.set("window", value)
    url.searchParams.delete("from")
    url.searchParams.delete("to")
    url.searchParams.delete("step")
    router.visit(url.toString(), { preserveScroll: true, preserveState: true })
  }

  // Sets an explicit ?from=&to= range, dropping the fixed `window` param.
  const setRange = (from: string, to: string) => {
    const url = new URL(globalThis.location.href)
    url.searchParams.set("from", from)
    url.searchParams.set("to", to)
    url.searchParams.delete("window")
    url.searchParams.delete("step")
    router.visit(url.toString(), { preserveScroll: true, preserveState: true })
  }

  const label =
    current === "custom" && range
      ? formatRange(range.from, range.to)
      : (WINDOWS.find((w) => w.value === current)?.label ?? current)

  return {
    window: current,
    from: range?.from,
    to: range?.to,
    set,
    setRange,
    label,
  }
}
