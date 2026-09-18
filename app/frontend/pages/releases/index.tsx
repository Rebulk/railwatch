import { Link, router, usePage } from "@inertiajs/react"
import { Package } from "lucide-react"

import { ChartPanel } from "@/components/railwatch/chart-panel"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { SessionStatusChart } from "@/components/railwatch/series-chart"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import EnvLayout from "@/layouts/env-layout"
import { count, ms, when } from "@/lib/format"
import { crashFreeTone, rate } from "@/pages/releases/release-health"
import { releasePath } from "@/pages/releases/release-path"
import type {
  ReleaseHealthSummary,
  SessionStatusPoint,
  SharedProps,
} from "@/types"

interface ReleaseRow extends ReleaseHealthSummary {
  deploy: string
  ref: string
  name: string | null
  deployed_at: string
  adoption: number
  new_issues: number
}

interface Props {
  releases: ReleaseRow[]
  series: SessionStatusPoint[]
  summary: ReleaseHealthSummary & { releases: number }
}

export default function Releases(p: Props) {
  const { environment, window: w } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  const href = (r: ReleaseRow) => releasePath(a, e, r.deploy, { window: w })
  const totals = p.series.reduce(
    (sum, point) => ({
      ok: sum.ok + point.ok,
      errored: sum.errored + point.errored,
      crashed: sum.crashed + point.crashed,
    }),
    { ok: 0, errored: 0, crashed: 0 },
  )
  return (
    <EnvLayout title="Releases">
      <PageHeader
        title="Releases"
        description="Sessions per deploy, and how many of them ended without a crash. A release is the deploy stamped on every record the gem ships."
      />
      <StatStrip>
        <Stat
          label="Crash-free sessions"
          value={rate(p.summary.crash_free_sessions)}
          tone={crashFreeTone(p.summary.crash_free_sessions)}
        />
        <Stat
          label="Crash-free users"
          value={rate(p.summary.crash_free_users)}
          tone={crashFreeTone(p.summary.crash_free_users)}
        />
        <Stat
          label="Sessions"
          value={count(p.summary.sessions)}
          hint={`${count(p.summary.users)} users`}
        />
        <Stat label="Active releases" value={count(p.summary.releases)} />
      </StatStrip>
      <ChartPanel
        label="Sessions by status"
        value={count(p.summary.sessions)}
        legend={[
          {
            key: "ok",
            label: "ok",
            value: count(totals.ok),
            color: "var(--ok)",
          },
          {
            key: "errored",
            label: "errored",
            value: count(totals.errored),
            color: "var(--warning)",
          },
          {
            key: "crashed",
            label: "crashed",
            value: count(totals.crashed),
            color: "var(--danger)",
          },
        ]}
      >
        <SessionStatusChart data={p.series} />
      </ChartPanel>
      <DataTable
        rows={p.releases}
        rowKey={(r) => r.deploy}
        empty={
          <EmptyState
            icon={Package}
            title="No releases in this window"
            description="A release appears once a deploy is recorded and the app reports sessions for it."
          />
        }
        onRowClick={(r) => router.visit(href(r))}
        keyboardNav={{
          onOpen: (r, opts) =>
            opts?.newTab
              ? globalThis.window.open(href(r), "_blank")
              : router.visit(href(r)),
        }}
        columns={[
          {
            key: "ref",
            header: "Release",
            cell: (r) => (
              <Link
                className="font-mono text-xs hover:underline"
                href={href(r)}
              >
                {r.ref}
              </Link>
            ),
          },
          {
            key: "at",
            header: "Deployed",
            cell: (r) => <span className="text-xs">{when(r.deployed_at)}</span>,
          },
          {
            key: "adoption",
            header: "Adoption",
            align: "right",
            cell: (r) => `${r.adoption}%`,
          },
          {
            key: "sessions",
            header: "Sessions",
            align: "right",
            cell: (r) => count(r.sessions),
          },
          {
            key: "cfs",
            header: "Crash-free sessions",
            align: "right",
            cell: (r) => (
              <span
                className={
                  crashFreeTone(r.crash_free_sessions) === "destructive"
                    ? "text-destructive font-semibold"
                    : "font-semibold"
                }
              >
                {rate(r.crash_free_sessions)}
              </span>
            ),
          },
          {
            key: "cfu",
            hideOnMobile: true,
            header: "Crash-free users",
            align: "right",
            cell: (r) => rate(r.crash_free_users),
          },
          {
            key: "issues",
            hideOnMobile: true,
            header: "New issues",
            align: "right",
            cell: (r) => (
              <span className={r.new_issues ? "text-destructive" : ""}>
                {count(r.new_issues)}
              </span>
            ),
          },
          {
            key: "duration",
            hideOnMobile: true,
            header: "Duration",
            align: "right",
            cell: (r) => ms(r.avg_duration_ms),
          },
        ]}
      />
    </EnvLayout>
  )
}
