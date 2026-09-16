import { Link, usePage } from "@inertiajs/react"
import { Flame } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, pct } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface ProfileGroup {
  group_hash: string
  name: string | null
  profile_id: number
  count: number
  avg_duration: number
  max_samples: number | null
  last_seen_at: string
}
interface Props {
  profiles: ProfileGroup[]
  summary: {
    profiles: number
    executions: number
    profiled: number
    avg_samples: number
  }
}

export default function Profiles(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const s = p.summary

  return (
    <EnvLayout title="Profiles">
      <PageHeader
        title="Profiles"
        description="Sampled stack profiles, grouped by the execution they profiled."
      />
      <StatStrip>
        <Stat label="Profiles" value={count(s.profiles)} />
        <Stat
          label="Executions profiled"
          value={pct(s.profiled, s.executions)}
          hint={`${count(s.profiled)} of ${count(s.executions)}`}
        />
        <Stat label="Avg samples" value={count(s.avg_samples)} />
      </StatStrip>
      <DataTable
        rows={p.profiles}
        rowKey={(g) => g.group_hash}
        empty={
          <EmptyState
            icon={Flame}
            title="No profiles in this window"
            description="Set RAILWATCH_PROFILE_SAMPLE_RATE in the app to profile slow executions."
          />
        }
        columns={[
          {
            key: "name",
            header: "Execution",
            className: "max-w-0",
            cell: (g) => (
              <Link
                href={R.applicationEnvironmentProfilePath(a, e, g.profile_id, {
                  window,
                })}
                className="block truncate font-mono text-xs hover:underline"
              >
                {g.name ?? g.group_hash}
              </Link>
            ),
          },
          {
            key: "n",
            header: "Profiles",
            align: "right",
            cell: (g) => count(g.count),
          },
          {
            key: "avg",
            header: "Avg duration",
            align: "right",
            cell: (g) => ms(g.avg_duration),
          },
          {
            key: "samples",
            hideOnMobile: true,
            header: "Max samples",
            align: "right",
            cell: (g) => count(g.max_samples),
          },
          {
            key: "last",
            hideOnMobile: true,
            header: "Last seen",
            align: "right",
            cell: (g) => <RelativeTime iso={g.last_seen_at} />,
          },
        ]}
      />
    </EnvLayout>
  )
}
