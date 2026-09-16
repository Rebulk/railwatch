import { Link, router, usePage } from "@inertiajs/react"

import { DataTable } from "@/components/railwatch/data-table"
import { PageHeader } from "@/components/railwatch/page-header"
import {
  IssueStatusBadge,
  StatusBadge,
} from "@/components/railwatch/status-badge"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { ago, ms, when } from "@/lib/format"
import * as R from "@/routes"
import type { ExecutionRow, SharedProps } from "@/types"

interface Props {
  person: {
    person_ref: string
    name: string
    email: string | null
    tenant: string | null
    first_seen_at: string
    last_seen_at: string
  } | null
  person_ref: string
  executions: ExecutionRow[]
  issues: {
    id: number
    key: string
    title: string
    status: string
    count: number
  }[]
}

export default function PersonShow(p: Props) {
  const { environment, window } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const name = p.person?.name ?? p.person_ref
  return (
    <EnvLayout
      title={name}
      crumbs={[
        {
          title: "Users",
          href: R.applicationEnvironmentPeoplePath(a, e, { window }),
        },
        { title: name, href: "#" },
      ]}
    >
      <PageHeader
        title={name}
        description={
          p.person
            ? `${p.person.email ?? ""} ${p.person.tenant ? `· tenant ${p.person.tenant}` : ""} · first seen ${ago(p.person.first_seen_at)} · last seen ${ago(p.person.last_seen_at)}`
            : "Not yet identified."
        }
      />
      {p.issues.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Issues affecting this user</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.issues}
              rowKey={(i) => i.id}
              columns={[
                {
                  key: "k",
                  header: "Issue",
                  cell: (i) => (
                    <Link
                      className="font-mono text-xs hover:underline"
                      href={R.issuePath(i.id)}
                    >
                      {i.key}
                    </Link>
                  ),
                },
                {
                  key: "t",
                  header: "Title",
                  cell: (i) => (
                    <span className="line-clamp-1 text-xs">{i.title}</span>
                  ),
                },
                {
                  key: "s",
                  header: "",
                  cell: (i) => <IssueStatusBadge status={i.status} />,
                },
                {
                  key: "n",
                  header: "Hits",
                  align: "right",
                  cell: (i) => i.count,
                },
              ]}
            />
          </CardContent>
        </Card>
      )}
      <DataTable
        rows={p.executions}
        rowKey={(x) => x.execution_id}
        onRowClick={(x) =>
          x.execution_id &&
          router.visit(
            R.applicationEnvironmentRequestPath(a, e, x.execution_id),
          )
        }
        columns={[
          {
            key: "when",
            header: "When",
            cell: (x) => <span className="text-xs">{when(x.occurred_at)}</span>,
          },
          { key: "k", header: "Kind", cell: (x) => x.kind },
          {
            key: "n",
            header: "Name",
            cell: (x) => <span className="font-mono text-xs">{x.name}</span>,
          },
          {
            key: "st",
            header: "Status",
            cell: (x) => <StatusBadge status={x.status} outcome={x.outcome} />,
          },
          {
            key: "d",
            header: "Duration",
            align: "right",
            cell: (x) => ms(x.duration),
          },
          {
            key: "ex",
            header: "Exception",
            cell: (x) => (
              <span className="text-destructive line-clamp-1 text-xs">
                {x.exception_preview ?? ""}
              </span>
            ),
          },
        ]}
      />
    </EnvLayout>
  )
}
