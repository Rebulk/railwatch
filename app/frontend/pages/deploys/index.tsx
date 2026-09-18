import { router, usePage } from "@inertiajs/react"
import { Rocket } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import EnvLayout from "@/layouts/env-layout"
import { count, when } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface DeployRow {
  id: number
  deploy: string
  ref: string
  name: string | null
  url: string | null
  server: string | null
  deployed_at: string
  commits_count: number
  performer: string | null
}

export default function Deploys(p: { deploys: DeployRow[] }) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const deployHref = (d: DeployRow) =>
    R.applicationEnvironmentDeployPath(a, e, d.id)
  return (
    <EnvLayout title="Deploys">
      <PageHeader
        withWindow={false}
        title="Deploys"
        description="Recorded by bin/rails railwatch:deploy or the Kamal post-deploy hook. Click one to compare the hour before and after."
      />
      <DataTable
        rows={p.deploys}
        rowKey={(d) => d.id}
        empty={
          <EmptyState
            icon={Rocket}
            title="No deploys recorded"
            description="Run bin/rails railwatch:deploy or install the Kamal hook to track deploys."
          />
        }
        onRowClick={(d) => router.visit(deployHref(d))}
        keyboardNav={{
          onOpen: (d, opts) =>
            opts?.newTab
              ? window.open(deployHref(d), "_blank")
              : router.visit(deployHref(d)),
        }}
        columns={[
          {
            key: "when",
            header: "When",
            cell: (d) => <span className="text-xs">{when(d.deployed_at)}</span>,
          },
          {
            key: "d",
            header: "Deploy",
            cell: (d) => <span className="font-mono text-xs">{d.deploy}</span>,
          },
          {
            key: "r",
            hideOnMobile: true,
            header: "Ref",
            cell: (d) => <span className="font-mono text-xs">{d.ref}</span>,
          },
          { key: "n", hideOnMobile: true, header: "Name", cell: (d) => d.name },
          {
            key: "by",
            hideOnMobile: true,
            header: "By",
            cell: (d) => <span className="text-xs">{d.performer}</span>,
          },
          {
            key: "c",
            hideOnMobile: true,
            header: "Commits",
            align: "right",
            cell: (d) => count(d.commits_count),
          },
          {
            key: "s",
            header: "Server",
            cell: (d) => <span className="font-mono text-xs">{d.server}</span>,
          },
        ]}
      />
    </EnvLayout>
  )
}
