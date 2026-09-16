import { useEffect, useState } from "react"

// Re-renders the calling component every `intervalMs`, so relative-time
// labels ("2m ago") and freshness checks stay current without a reload.
export function useTicker(intervalMs = 30_000) {
  const [, setTick] = useState(0)

  useEffect(() => {
    const id = window.setInterval(() => setTick((tick) => tick + 1), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])
}
