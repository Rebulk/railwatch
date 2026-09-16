import { Sparkline } from "@/components/railwatch/series-chart"

// Compact trend cell for a DataTable row: a 32x10 area chart, no axes.
// `hoverKey` (typically the row's group_hash) wires it into
// ChartHoverProvider so hovering the row emphasizes its own sparkline.
export function SparklineCell({
  data,
  hoverKey,
}: {
  data: number[]
  hoverKey?: string
}) {
  return <Sparkline data={data} className="h-[10px] w-8" hoverKey={hoverKey} />
}
