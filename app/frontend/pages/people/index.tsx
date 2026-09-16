import { router, usePage } from "@inertiajs/react"
import { Users } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import EnvLayout from "@/layouts/env-layout"
import { ago, count } from "@/lib/format"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Person {
  ref: string
  requests: number
  errors: number
  last_seen_at: string
  name: string | null
  email: string | null
  tenant: string | null
}
interface Props {
  people: Person[]
}

export default function People(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const personHref = (x: Person) =>
    R.applicationEnvironmentPersonPath(a, e, x.ref)
  return (
    <EnvLayout title="Users">
      <PageHeader
        title="Users"
        description="Your application's users as seen in telemetry, with their activity and errors."
      />
      <DataTable
        rows={p.people}
        rowKey={(x) => x.ref}
        empty={
          <EmptyState
            icon={Users}
            title="No authenticated activity in this window"
            description="People appear here once requests are tagged with an authenticated user."
          />
        }
        onRowClick={(x) => router.visit(personHref(x))}
        keyboardNav={{
          onOpen: (x, opts) =>
            opts?.newTab
              ? window.open(personHref(x), "_blank")
              : router.visit(personHref(x)),
        }}
        columns={[
          {
            key: "n",
            header: "User",
            cell: (x) => (
              <span className="text-xs">
                <span className="font-medium">{x.name ?? x.ref}</span>
                {x.email && (
                  <span className="text-muted-foreground"> · {x.email}</span>
                )}
              </span>
            ),
          },
          {
            key: "t",
            hideOnMobile: true,
            header: "Tenant",
            cell: (x) => (
              <span className="font-mono text-xs">{x.tenant ?? ""}</span>
            ),
          },
          {
            key: "r",
            header: "Requests",
            align: "right",
            cell: (x) => count(x.requests),
          },
          {
            key: "e",
            hideOnMobile: true,
            header: "Errors",
            align: "right",
            cell: (x) => (
              <span className={x.errors ? "text-destructive" : ""}>
                {x.errors}
              </span>
            ),
          },
          {
            key: "l",
            header: "Last seen",
            align: "right",
            cell: (x) => ago(x.last_seen_at),
          },
        ]}
      />
    </EnvLayout>
  )
}
