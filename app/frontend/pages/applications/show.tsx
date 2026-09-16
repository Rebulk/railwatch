import { Head, Link, router } from "@inertiajs/react"

import { DataTable } from "@/components/railwatch/data-table"
import { Onboarding } from "@/components/railwatch/onboarding"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import AppLayout from "@/layouts/app-layout"
import { ago, count } from "@/lib/format"
import * as R from "@/routes"

interface Env {
  id: number
  name: string
  slug: string
  token_prefix: string
  last_seen_at: string | null
  paused: boolean
  events_this_month: number
  deploys_count: number
  open_issues: number
}
interface Props {
  application: {
    id: number
    name: string
    slug: string
    issue_prefix: string
    issues_count: number
  }
  environments: Env[]
  new_token: string | null
  issues_open: number
}

export default function ApplicationShow(p: Props) {
  const app = p.application
  return (
    <AppLayout
      breadcrumbs={[{ title: app.name, href: R.applicationPath(app.id) }]}
    >
      <Head title={app.name} />
      <div className="flex flex-1 flex-col gap-4 p-3 md:gap-5 md:px-6 md:pt-2 md:pb-6">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h1 className="text-xl font-semibold">{app.name}</h1>
            <p className="text-muted-foreground text-sm">
              Issue prefix <span className="font-mono">{app.issue_prefix}</span>{" "}
              · {p.issues_open} open issues
            </p>
          </div>
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => router.visit(R.editApplicationPath(app.id))}
            >
              Edit
            </Button>
            <Button
              size="sm"
              onClick={() =>
                router.visit(R.newApplicationEnvironmentPath(app.id))
              }
            >
              Add environment
            </Button>
          </div>
        </div>
        {p.new_token &&
          (() => {
            const newToken = p.new_token
            const env = p.environments.find(
              (e) => e.token_prefix === newToken.slice(0, 12),
            )
            return (
              <Onboarding
                tokenPrefix={env?.token_prefix ?? newToken.slice(0, 12)}
                newToken={newToken}
              />
            )
          })()}
        <DataTable
          rows={p.environments}
          rowKey={(e) => e.id}
          columns={[
            {
              key: "n",
              header: "Environment",
              cell: (e) => (
                <Link
                  className="font-medium hover:underline"
                  href={R.applicationEnvironmentOverviewPath(app.id, e.id)}
                >
                  {e.name}
                </Link>
              ),
            },
            {
              key: "tok",
              header: "Token",
              cell: (e) => (
                <span className="font-mono text-xs">{e.token_prefix}…</span>
              ),
            },
            {
              key: "seen",
              header: "Last event",
              cell: (e) =>
                e.last_seen_at ? (
                  ago(e.last_seen_at)
                ) : (
                  <span className="text-muted-foreground">never</span>
                ),
            },
            {
              key: "ev",
              header: "Events (month)",
              align: "right",
              cell: (e) => count(e.events_this_month),
            },
            {
              key: "d",
              header: "Deploys",
              align: "right",
              cell: (e) => e.deploys_count,
            },
            {
              key: "i",
              header: "Open issues",
              align: "right",
              cell: (e) =>
                e.open_issues ? (
                  <Badge variant="destructive">{e.open_issues}</Badge>
                ) : (
                  0
                ),
            },
            {
              key: "st",
              header: "",
              cell: (e) =>
                e.paused ? <Badge variant="secondary">paused</Badge> : null,
            },
            {
              key: "x",
              header: "",
              align: "right",
              cell: (e) => (
                <span className="flex justify-end gap-1">
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() =>
                      router.post(
                        R.rotateTokenApplicationEnvironmentPath(app.id, e.id),
                      )
                    }
                  >
                    Rotate token
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() =>
                      router.post(
                        R.pauseApplicationEnvironmentPath(app.id, e.id),
                      )
                    }
                  >
                    {e.paused ? "Resume" : "Pause"}
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-destructive"
                    onClick={() =>
                      confirm(`Delete ${e.name} and all its telemetry?`) &&
                      router.delete(R.applicationEnvironmentPath(app.id, e.id))
                    }
                  >
                    Delete
                  </Button>
                </span>
              ),
            },
          ]}
        />
      </div>
    </AppLayout>
  )
}
