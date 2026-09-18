import { router, usePage } from "@inertiajs/react"
import { Layers } from "lucide-react"

import { VolumePanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { FilterBar } from "@/components/railwatch/filter-bar"
import { PageHeader } from "@/components/railwatch/page-header"
import { SparklineCell } from "@/components/railwatch/sparkline-cell"
import EnvLayout from "@/layouts/env-layout"
import { count, ms } from "@/lib/format"
import * as R from "@/routes"
import type { SeriesPoint, SharedProps } from "@/types"

interface Key {
  group_hash: string
  key: string
  count: number
  hits: number
  misses: number
  hit_rate: number | null
  avg: number
  sparkline: number[]
}
interface Props {
  keys: Key[]
  series: SeriesPoint[]
  q: string
}

export default function CacheEvents(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  return (
    <EnvLayout title="Cache">
      <PageHeader
        title="Cache"
        description="Rails.cache reads, writes, and hit rates by key shape (ids collapsed)."
      />
      <VolumePanel
        legend="cache"
        label="Cache ops"
        seriesLabel="Cache ops"
        data={p.series}
      />
      <FilterBar
        value={p.q}
        fields={[{ key: "store", label: "Store" }]}
        onChange={(q) =>
          router.visit(
            R.applicationEnvironmentCacheEventsPath(a, e, {
              window,
              q: q || undefined,
            }),
            { preserveState: true },
          )
        }
        placeholder="store:MemoryStore"
      />
      <DataTable
        rows={p.keys}
        rowKey={(k) => k.group_hash}
        empty={
          <EmptyState
            icon={Layers}
            title="No cache activity in this window"
            description="Cache reads and writes instrumented by the gem appear here."
          />
        }
        columns={[
          {
            key: "k",
            header: "Store · key",
            cell: (k) => <span className="font-mono text-xs">{k.key}</span>,
          },
          {
            key: "trend",
            hideOnMobile: true,
            header: "Trend",
            cell: (k) => <SparklineCell data={k.sparkline} />,
          },
          {
            key: "n",
            header: "Ops",
            align: "right",
            cell: (k) => count(k.count),
          },
          {
            key: "h",
            header: "Hits",
            align: "right",
            cell: (k) => count(k.hits),
          },
          {
            key: "m",
            hideOnMobile: true,
            header: "Misses",
            align: "right",
            cell: (k) => count(k.misses),
          },
          {
            key: "r",
            hideOnMobile: true,
            header: "Hit rate",
            align: "right",
            cell: (k) =>
              k.hit_rate == null ? (
                "–"
              ) : (
                <span className={k.hit_rate < 50 ? "text-amber-600" : ""}>
                  {k.hit_rate}%
                </span>
              ),
          },
          {
            key: "avg",
            hideOnMobile: true,
            header: "Avg",
            align: "right",
            cell: (k) => ms(k.avg, 3),
          },
        ]}
      />
    </EnvLayout>
  )
}
