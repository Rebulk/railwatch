import { Segmented, SegmentedItem } from "@/components/railwatch/segmented"
import { usePercentile } from "@/hooks/use-percentile"
import type { Percentile } from "@/types"

const PERCENTILES: Percentile[] = ["p50", "p95", "p99"]

export function PercentilePicker() {
  const { percentile, set } = usePercentile()
  return (
    <Segmented>
      {PERCENTILES.map((p) => (
        <SegmentedItem key={p} active={percentile === p} onClick={() => set(p)}>
          {p}
        </SegmentedItem>
      ))}
    </Segmented>
  )
}
