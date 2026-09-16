import { Link, usePage } from "@inertiajs/react"
import { AlertOctagon, GitCommitHorizontal } from "lucide-react"

import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { IssueStatusBadge } from "@/components/railwatch/status-badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, pct, when } from "@/lib/format"
import { commitUrl, compareUrl } from "@/lib/source-link"
import { ReleaseHealthStrip } from "@/pages/releases/release-health"
import * as R from "@/routes"
import type { ReleaseHealthSummary, SharedProps, Summary } from "@/types"

interface Commit {
  sha: string
  author: string | null
  message: string | null
  at: string | null
}

interface Props {
  deploy: {
    id: number
    deploy: string
    ref: string
    name: string | null
    url: string | null
    server: string | null
    deployed_at: string
    commits: Commit[]
    previous_ref: string | null
    repository_ref: string | null
    detail: Record<string, string>
  }
  compare: Record<string, { before: Summary; after: Summary }>
  health: ReleaseHealthSummary
  new_issues: { id: number; key: string; title: string; status: string }[]
  resolved_issues: { id: number; key: string; title: string }[]
}

function delta(before: number, after: number) {
  if (!before) return null
  const d = ((after - before) / before) * 100
  return (
    <span
      className={
        d > 10
          ? "text-destructive"
          : d < -10
            ? "text-emerald-600"
            : "text-muted-foreground"
      }
    >
      {d > 0 ? "+" : ""}
      {d.toFixed(0)}%
    </span>
  )
}

export default function DeployShow(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const r = p.compare.request
  const j = p.compare.job_attempt
  const repositoryUrl = environment!.repository_url
  const compare = compareUrl(
    repositoryUrl,
    p.deploy.previous_ref,
    p.deploy.repository_ref,
  )
  const codeHost = repositoryUrl?.includes("gitlab") ? "GitLab" : "GitHub"
  return (
    <EnvLayout
      title={p.deploy.ref}
      crumbs={[
        { title: "Deploys", href: R.applicationEnvironmentDeploysPath(a, e) },
        { title: p.deploy.ref, href: "#" },
      ]}
    >
      <PageHeader
        withWindow={false}
        title={<span className="font-mono">{p.deploy.deploy}</span>}
        description={`${when(p.deploy.deployed_at)}${p.deploy.name ? ` · ${p.deploy.name}` : ""}${p.deploy.url ? " · " : ""}`}
        actions={
          p.deploy.url && (
            <a
              className="text-sm underline"
              href={p.deploy.url}
              target="_blank"
              rel="noreferrer"
            >
              Open
            </a>
          )
        }
      />
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold">
          Changes
          {p.deploy.previous_ref && (
            <span className="text-muted-foreground ml-2 font-mono text-xs font-normal">
              since {p.deploy.previous_ref.slice(0, 7)}
            </span>
          )}
        </h2>
        {compare && (
          <Button asChild variant="outline" size="sm">
            <a href={compare} target="_blank" rel="noreferrer">
              Compare on {codeHost}
            </a>
          </Button>
        )}
      </div>
      <DataTable
        rows={p.deploy.commits}
        rowKey={(c) => c.sha}
        empty={
          <EmptyState
            icon={GitCommitHorizontal}
            title="No commits recorded"
            description="The post-deploy hook sends the commits in each deploy. Reinstall it with bin/rails generate railwatch:install."
          />
        }
        columns={[
          {
            key: "sha",
            header: "Commit",
            cell: (c) => {
              const url = commitUrl(repositoryUrl, c.sha)
              const short = c.sha.slice(0, 7)
              return url ? (
                <a
                  className="font-mono text-xs hover:underline"
                  href={url}
                  target="_blank"
                  rel="noreferrer"
                >
                  {short}
                </a>
              ) : (
                <span className="font-mono text-xs">{short}</span>
              )
            },
          },
          {
            key: "m",
            header: "Message",
            cell: (c) => (
              <span className="line-clamp-1 text-xs">{c.message}</span>
            ),
          },
          {
            key: "a",
            hideOnMobile: true,
            header: "Author",
            cell: (c) => <span className="text-xs">{c.author}</span>,
          },
          {
            key: "at",
            hideOnMobile: true,
            header: "When",
            align: "right",
            cell: (c) => <RelativeTime className="text-xs" iso={c.at} />,
          },
        ]}
      />
      <h2 className="text-sm font-semibold">Release health</h2>
      <ReleaseHealthStrip health={p.health} />
      <h2 className="text-sm font-semibold">Hour before vs hour after</h2>
      <StatStrip>
        <Stat
          label="Request p95"
          value={
            <>
              {ms(r.after.p95 / 1000)} {delta(r.before.p95, r.after.p95)}
            </>
          }
          hint={`was ${ms(r.before.p95 / 1000)}`}
        />
        <Stat
          label="Request error rate"
          value={
            <>
              {pct(r.after.errors, r.after.count)}{" "}
              {delta(
                r.before.errors / Math.max(1, r.before.count),
                r.after.errors / Math.max(1, r.after.count),
              )}
            </>
          }
          hint={`was ${pct(r.before.errors, r.before.count)}`}
        />
        <Stat
          label="Requests"
          value={
            <>
              {count(r.after.count)} {delta(r.before.count, r.after.count)}
            </>
          }
          hint={`was ${count(r.before.count)}`}
        />
        <Stat
          label="Job failures"
          value={
            <>
              {pct(j.after.errors, j.after.count)}{" "}
              {delta(
                j.before.errors / Math.max(1, j.before.count),
                j.after.errors / Math.max(1, j.after.count),
              )}
            </>
          }
          hint={`was ${pct(j.before.errors, j.before.count)}`}
        />
      </StatStrip>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>New issues after this deploy</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.new_issues}
              rowKey={(i) => i.id}
              empty={
                <EmptyState
                  icon={AlertOctagon}
                  title="No new issues in the 24 hours after"
                  description="Issues first seen after this deploy would show here."
                />
              }
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
              ]}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Resolved in this deploy</CardTitle>
          </CardHeader>
          <CardContent>
            <DataTable
              rows={p.resolved_issues}
              rowKey={(i) => i.id}
              empty={
                <EmptyState
                  icon={AlertOctagon}
                  title="No issues marked resolved in this deploy"
                  description="Issues resolved and tagged with this deploy's ref would show here."
                />
              }
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
              ]}
            />
          </CardContent>
        </Card>
      </div>
    </EnvLayout>
  )
}
