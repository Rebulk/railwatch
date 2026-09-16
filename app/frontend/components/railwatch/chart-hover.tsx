import { createContext, useContext, useMemo, useState } from "react"
import type { ReactNode } from "react"

interface ChartHoverContextValue {
  hoveredKey: string | null
  setHoveredKey: (key: string | null) => void
}

const noop = () => undefined
const fallback: ChartHoverContextValue = {
  hoveredKey: null,
  setHoveredKey: noop,
}

const ChartHoverContext = createContext<ChartHoverContextValue>(fallback)

// Links a chart to the table below it: hovering a chart point (bucket time)
// or a table row (its group_hash) sets one shared `hoveredKey`, so
// `SeriesChart`/`Sparkline` can highlight the matching point and `DataTable`
// can style the matching row. Using the context outside a provider is safe —
// it falls back to a no-op so call sites don't need to check.
export function ChartHoverProvider({ children }: { children: ReactNode }) {
  const [hoveredKey, setHoveredKey] = useState<string | null>(null)
  const value = useMemo(() => ({ hoveredKey, setHoveredKey }), [hoveredKey])
  return (
    <ChartHoverContext.Provider value={value}>
      {children}
    </ChartHoverContext.Provider>
  )
}

export function useChartHover() {
  return useContext(ChartHoverContext)
}
