import { Head, Link, router, usePage } from "@inertiajs/react"
import { AlertOctagon, Search } from "lucide-react"
import { useEffect, useState } from "react"

import { DataTable, type KeyboardNav } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { Segmented, SegmentedItem } from "@/components/railwatch/segmented"
import { IssueStatusBadge } from "@/components/railwatch/status-badge"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import AppLayout from "@/layouts/app-layout"
import { ago, count } from "@/lib/format"
import { ignorePageShortcut } from "@/lib/keyboard"
import * as R from "@/routes"
import type { IssueRow, SharedProps } from "@/types"

interface Props {
  issues: IssueRow[]
  filters: Record<string, string>
  counts: Record<string, number>
  kindCounts?: Record<string, number>
  members: { id: number; name: string }[]
}

const BULK_PRIORITIES = ["low", "normal", "high", "urgent"]

export default function Issues(p: Props) {
  const { applications } = usePage<SharedProps>().props
  const [q, setQ] = useState(p.filters.q ?? "")
  const [highlightedId, setHighlightedId] = useState<number | null>(null)
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const status = p.filters.status ?? "open"
  const apply = (patch: Record<string, string | undefined>) =>
    router.visit(R.issuesPath({ ...p.filters, ...patch }), {
      preserveState: true,
    })

  // j/k/Enter/o/Esc row navigation lives in useRowNav, wired in via
  // DataTable's keyboardNav prop below. r/i/a act on whichever row that
  // hook currently has highlighted, so we mirror it into local state via
  // onHighlightChange.
  const issueHref = (i: IssueRow) => R.issuePath(i.id)
  const keyboardNav: KeyboardNav<IssueRow> = {
    onOpen: (i, opts) =>
      opts?.newTab
        ? window.open(issueHref(i), "_blank")
        : router.visit(issueHref(i)),
    onHighlightChange: (i) => setHighlightedId(i?.id ?? null),
  }

  useEffect(() => {
    function onKeyDown(ev: KeyboardEvent) {
      if (ignorePageShortcut(ev)) return
      if (ev.key !== "r" && ev.key !== "i" && ev.key !== "a") return
      const index = p.issues.findIndex((i) => i.id === highlightedId)
      if (index < 0) return
      ev.preventDefault()
      const actionName =
        ev.key === "r" ? "resolve" : ev.key === "i" ? "ignore" : "assign_me"
      router.patch(
        R.issuePath(p.issues[index].id),
        { action_name: actionName },
        { preserveScroll: true },
      )
    }
    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [highlightedId, p.issues])

  function toggleSelected(id: number) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function bulkAction(actionName: string, value?: string) {
    router.post(
      R.bulkIssuesPath(),
      { ids: [...selected], action_name: actionName, value },
      { preserveScroll: true, onSuccess: () => setSelected(new Set()) },
    )
  }

  return (
    <AppLayout breadcrumbs={[{ title: "Issues", href: R.issuesPath() }]}>
      <Head title="Issues" />
      <div className="flex flex-1 flex-col gap-4 p-3 md:gap-5 md:px-6 md:pt-2 md:pb-6">
        <div className="flex flex-col gap-2 md:flex-row md:flex-wrap md:items-center">
          <Segmented>
            {[
              ["exception", "Exceptions"],
              ["performance", "Performance"],
              ["anomaly", "Anomalies"],
            ].map(([kind, label]) => (
              <SegmentedItem
                key={kind}
                mono={false}
                active={(p.filters.kind ?? "") === kind}
                onClick={() =>
                  apply({ kind: p.filters.kind === kind ? undefined : kind })
                }
                className="gap-2 px-3"
              >
                {label}
                <span className="bg-muted text-muted-foreground rounded px-1.5 font-mono text-[10px]">
                  {count(p.kindCounts?.[kind] ?? 0)}
                </span>
              </SegmentedItem>
            ))}
          </Segmented>
          <form
            className="bg-card flex h-8 min-w-0 flex-1 items-center gap-1.5 rounded-md border px-2 md:max-w-xs"
            onSubmit={(ev) => {
              ev.preventDefault()
              apply({ q })
            }}
          >
            <Search className="text-muted-foreground size-3.5 shrink-0" />
            <input
              value={q}
              onChange={(ev) => setQ(ev.target.value)}
              placeholder="Search or source:browser"
              className="placeholder:text-muted-foreground min-w-0 flex-1 bg-transparent text-sm outline-none"
            />
          </form>
          <div className="-mx-3 [scrollbar-width:none] overflow-x-auto px-3 md:mx-0 md:ml-auto md:overflow-visible md:px-0 [&::-webkit-scrollbar]:hidden">
            <Segmented>
              {[
                ["open", "Open", {}],
                ["mine", "Mine", { mine: "1" }],
                ["resolved", "Resolved", {}],
                ["ignored", "Ignored", {}],
              ].map(([key, label, extra]) => {
                const isMine = key === "mine"
                const active = isMine
                  ? p.filters.mine === "1"
                  : status === key && p.filters.mine !== "1"
                return (
                  <SegmentedItem
                    key={key as string}
                    mono={false}
                    active={active}
                    onClick={() =>
                      apply(
                        isMine
                          ? { mine: "1", status: "open" }
                          : {
                              status: key as string,
                              mine: undefined,
                              ...(extra as object),
                            },
                      )
                    }
                    className="px-3"
                  >
                    {label as string}
                    {!isMine && (
                      <span className="text-muted-foreground font-mono text-[10px]">
                        {count(p.counts[key as string] ?? 0)}
                      </span>
                    )}
                  </SegmentedItem>
                )
              })}
            </Segmented>
          </div>
          {applications.length > 1 && (
            <Select
              value={p.filters.application_id ?? "all"}
              onValueChange={(v) =>
                apply({
                  application_id: v === "all" ? undefined : v,
                  environment_id: undefined,
                })
              }
            >
              <SelectTrigger className="h-8 w-44 text-xs">
                <SelectValue placeholder="Application" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All applications</SelectItem>
                {applications.map((a) => (
                  <SelectItem key={a.id} value={String(a.id)}>
                    {a.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </div>
        <DataTable
          rows={p.issues}
          rowKey={(i) => i.id}
          empty={
            <EmptyState
              icon={AlertOctagon}
              title="No issues match"
              signal="caution"
              description="Issues are grouped from repeated request, job, and exception errors."
            />
          }
          onRowClick={(i) => router.visit(issueHref(i))}
          keyboardNav={keyboardNav}
          columns={[
            {
              key: "sel",
              hideOnMobile: true,
              header: (
                <Checkbox
                  checked={
                    p.issues.length > 0 && selected.size === p.issues.length
                  }
                  onCheckedChange={(v) =>
                    setSelected(
                      v ? new Set(p.issues.map((i) => i.id)) : new Set(),
                    )
                  }
                  aria-label="Select all"
                  onClick={(ev) => ev.stopPropagation()}
                />
              ),
              cell: (i) => (
                <Checkbox
                  checked={selected.has(i.id)}
                  onCheckedChange={() => toggleSelected(i.id)}
                  aria-label={`Select ${i.key}`}
                  onClick={(ev) => ev.stopPropagation()}
                />
              ),
            },
            {
              key: "k",
              header: "Issue",
              cell: (i) => (
                <div className="flex items-center gap-1">
                  {i.id === highlightedId && (
                    <span className="text-primary" aria-hidden>
                      ›
                    </span>
                  )}
                  <Link
                    className="font-mono text-xs font-semibold hover:underline"
                    href={issueHref(i)}
                  >
                    {i.key}
                  </Link>
                </div>
              ),
            },
            {
              key: "t",
              header: "Title",
              grow: true,
              cell: (i) => (
                <div className="text-xs">
                  <div className="flex items-center gap-2">
                    <span className="line-clamp-1 font-medium">{i.title}</span>
                    {i.fingerprint_source &&
                      i.fingerprint_source !== "default" && (
                        <Badge variant="secondary" className="shrink-0">
                          grouped by {i.fingerprint_source}
                        </Badge>
                      )}
                    <span className="md:hidden">
                      <IssueStatusBadge status={i.status} />
                    </span>
                  </div>
                  <div className="text-muted-foreground font-mono">
                    {i.culprit}
                  </div>
                </div>
              ),
            },
            {
              key: "env",
              hideOnMobile: true,
              header: "Where",
              cell: (i) => (
                <span className="text-xs">
                  {i.application?.name} · {i.environment?.name}
                </span>
              ),
            },
            {
              key: "kind",
              hideOnMobile: true,
              header: "Kind",
              cell: (i) => <Badge variant="outline">{i.kind}</Badge>,
            },
            {
              key: "s",
              hideOnMobile: true,
              header: "Status",
              cell: (i) => <IssueStatusBadge status={i.status} />,
            },
            {
              key: "p",
              hideOnMobile: true,
              header: "Priority",
              cell: (i) => (
                <span
                  className={
                    i.priority === "urgent"
                      ? "text-destructive font-semibold"
                      : i.priority === "high"
                        ? "text-amber-600"
                        : "text-muted-foreground"
                  }
                >
                  {i.priority}
                </span>
              ),
            },
            {
              key: "a",
              hideOnMobile: true,
              header: "Assignee",
              cell: (i) =>
                i.assignee?.name ?? (
                  <span className="text-muted-foreground">–</span>
                ),
            },
            {
              key: "n",
              header: "Events",
              align: "right",
              cell: (i) => count(i.occurrences),
            },
            {
              key: "u",
              hideOnMobile: true,
              header: "Users",
              align: "right",
              cell: (i) => i.affected_users,
            },
            {
              key: "l",
              hideOnMobile: true,
              header: "Last seen",
              align: "right",
              cell: (i) => (
                <span title={i.last_seen_at}>{ago(i.last_seen_at)}</span>
              ),
            },
          ]}
        />
        {selected.size > 0 && (
          <div className="bg-background sticky bottom-4 z-10 flex w-fit items-center gap-2 self-start rounded-lg border p-2 shadow-md">
            <span className="px-1 text-sm">{selected.size} selected</span>
            <Button
              size="sm"
              variant="outline"
              onClick={() => bulkAction("resolve")}
            >
              Resolve
            </Button>
            <Button
              size="sm"
              variant="outline"
              onClick={() => bulkAction("ignore")}
            >
              Ignore
            </Button>
            <Select onValueChange={(v) => bulkAction("priority", v)}>
              <SelectTrigger className="h-8 w-32">
                <SelectValue placeholder="Priority" />
              </SelectTrigger>
              <SelectContent>
                {BULK_PRIORITIES.map((pr) => (
                  <SelectItem key={pr} value={pr} className="capitalize">
                    {pr}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => setSelected(new Set())}
            >
              Clear
            </Button>
          </div>
        )}
      </div>
    </AppLayout>
  )
}
