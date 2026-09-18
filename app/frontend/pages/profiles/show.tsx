import { Link, usePage } from "@inertiajs/react"

import { Flamegraph } from "@/components/railwatch/flamegraph"
import { PageHeader } from "@/components/railwatch/page-header"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { Card, CardContent } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { executionPath } from "@/lib/execution-path"
import { bytes, count, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Props {
  profile: {
    id: number
    profiler: string
    mode: string | null
    interval: number | null
    duration: number
    samples: number
    stacks_bytes: number | null
    group_hash: string | null
    execution_id: string | null
    execution_preview: string | null
    execution_source: string | null
    occurred_at: string
    deploy: string | null
    server: string | null
  }
  collapsed: string
  truncated: boolean
}

export default function ProfileShow(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const x = p.profile

  return (
    <EnvLayout
      title={x.execution_preview ?? "Profile"}
      crumbs={[
        {
          title: "Profiles",
          href: R.applicationEnvironmentProfilesPath(a, e, { window }),
        },
        { title: x.execution_preview ?? `Profile ${x.id}`, href: "#" },
      ]}
    >
      <PageHeader
        withWindow={false}
        title={
          <span className="font-mono">
            {x.execution_preview ?? `Profile ${x.id}`}
          </span>
        }
        description={
          <span className="flex flex-wrap gap-x-3 text-xs">
            <span>{when(x.occurred_at)}</span>
            <span>
              {x.profiler}
              {x.mode ? ` · ${x.mode}` : ""}
            </span>
            {x.server && <span>server {x.server}</span>}
            {x.deploy && <span>deploy {x.deploy.slice(0, 12)}</span>}
            {x.execution_id && (
              <Link
                className="hover:underline"
                href={executionPath({
                  applicationId: a,
                  environmentId: e,
                  source: x.execution_source,
                  executionId: x.execution_id,
                })!}
              >
                view execution
              </Link>
            )}
          </span>
        }
      />
      <StatStrip>
        <Stat label="Samples" value={count(x.samples)} />
        <Stat
          label="Duration"
          value={ms(x.duration)}
          hint={x.interval ? `every ${ms(x.interval / 1000, 2)}` : undefined}
        />
        <Stat label="Profiler" value={x.profiler} hint={x.mode ?? undefined} />
        <Stat
          label="Stacks"
          value={bytes(x.stacks_bytes)}
          hint={p.truncated ? "truncated for display" : "uncompressed"}
          tone={p.truncated ? "warning" : undefined}
        />
      </StatStrip>
      <Card>
        <CardContent className="pt-4">
          <Flamegraph collapsed={p.collapsed} />
        </CardContent>
      </Card>
    </EnvLayout>
  )
}
