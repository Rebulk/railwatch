import { Bell, Check } from "lucide-react"

import { LiveDot } from "@/components/railwatch/live-dot"
import { Stat, StatStrip } from "@/components/railwatch/stat"
import { IssueStatusBadge } from "@/components/railwatch/status-badge"
import { Timeline } from "@/components/railwatch/timeline"
import { Card, CardContent, CardHeader } from "@/components/ui/card"
import { cn } from "@/lib/utils"
import type { TimelineEntry } from "@/types"

import { useHeroStage } from "./hero-line"

// Demo data — a fake-but-honest request, rendered with the same Stat and
// Timeline components the real dashboard uses. It follows the hero's
// stage: while the train is held at red, the request has thrown and the
// exception sits in the timeline with an open issue; when the signal
// clears, the issue is resolved and the error rate drops.
const DEMO_ENTRIES: TimelineEntry[] = [
  {
    type: "query",
    id: 1,
    offset: 2,
    duration: 4.2,
    label: "SELECT users",
    stage: "action",
    sql: 'SELECT "users".* FROM "users" WHERE "users"."id" = ?',
  },
  {
    type: "cache_event",
    id: 2,
    offset: 8,
    duration: 0.4,
    label: "read widgets/42",
    stage: "action",
    detail: { op: "read", key: "widgets/42" },
  },
  {
    type: "query",
    id: 3,
    offset: 11,
    duration: 12.8,
    label: "SELECT widgets",
    stage: "action",
    sql: 'SELECT "widgets".* FROM "widgets" WHERE "widgets"."account_id" = ?',
  },
  {
    type: "outgoing_request",
    id: 4,
    offset: 26,
    duration: 40.1,
    label: "GET api.stripe.com",
    stage: "action",
    detail: {
      method: "GET",
      url: "https://api.stripe.com/v1/charges",
      status: 200,
    },
  },
  {
    type: "view_render",
    id: 5,
    offset: 68,
    duration: 6.5,
    label: "widgets/index.html.erb",
    stage: "render",
  },
  {
    type: "enqueued_job",
    id: 6,
    offset: 70,
    duration: null,
    label: "WidgetSyncJob",
    stage: "render",
  },
]

// The exception the train stops for, as the timeline would show it: raised
// just after the Stripe call returned, in the action stage.
const EXCEPTION_ENTRY: TimelineEntry = {
  type: "exception",
  id: 7,
  offset: 66.4,
  duration: null,
  label: "NoMethodError: undefined method `total' for nil",
  stage: "action",
  source: "app/controllers/widgets_controller.rb:31",
}

export function ProductPreview() {
  const stage = useHeroStage()
  // Healthy while the train rolls in. The environment's status head goes
  // red as the train brakes (the app has started failing); the request and
  // issue follow once it is held, and everything is resolved after that and
  // on the still frame.
  const erroring = stage === "braking" || stage === "held"
  const faulted = stage === "held"
  const entries = faulted ? [...DEMO_ENTRIES, EXCEPTION_ENTRY] : DEMO_ENTRIES
  // The alert Railwatch sent, as it would appear in the alerts feed: a new
  // issue when the fault lands, delivered to Slack; resolved when the line
  // clears. Nothing before the fault, nothing once the train has gone.
  const alert =
    stage === "held"
      ? "new"
      : stage === "caution" || stage === "clear"
        ? "resolved"
        : null

  return (
    <section className="relative z-20 mx-auto -mt-8 max-w-5xl px-6 pb-16 md:-mt-4">
      <Card className="overflow-hidden">
        <CardHeader className="relative flex-row items-center justify-between overflow-hidden border-b pb-6 max-md:flex-wrap max-md:gap-y-3">
          <div className="flex items-center gap-2 text-sm font-medium">
            <LiveDot
              lastSeenAt={new Date().toISOString()}
              erroring={erroring}
            />
            storefront · production
          </div>
          <span className="text-muted-foreground flex items-center gap-2 font-mono text-xs">
            GET /widgets
            <span
              className={cn(
                "rounded px-1.5 py-0.5 font-semibold transition-colors duration-500",
                faulted ? "bg-danger/15 text-danger" : "bg-live/15 text-live",
              )}
            >
              {faulted ? "500" : "200"}
            </span>
          </span>
          {/* The alert as the alerts feed would show it. It slides in over
              the header's right end and out again, so the stats and the
              waterfall below never move. On a phone the environment name
              can reach most of the way across, so the alert sits beside
              the shorter route row instead, as a two-line card with a
              shorter Slack line. */}
          <div
            aria-live="polite"
            className={cn(
              "bg-popover absolute right-0 flex items-center gap-2 border-l px-3 text-xs shadow-[-12px_0_16px_-8px_rgba(0,0,0,.5)] transition-transform duration-500 ease-out motion-reduce:transition-none",
              "max-md:bottom-2.5 max-md:gap-1.5 max-md:rounded-l-md max-md:border-y max-md:px-2.5 max-md:py-1.5 max-md:text-[11px] md:inset-y-0",
              alert ? "translate-x-0" : "translate-x-[calc(100%+2px)]",
            )}
          >
            <span
              className={cn(
                "flex size-6 shrink-0 items-center justify-center rounded-full",
                alert === "resolved"
                  ? "bg-live/15 text-live"
                  : "bg-danger/15 text-danger",
              )}
            >
              {alert === "resolved" ? (
                <Check className="size-3.5" />
              ) : (
                <Bell className="size-3.5" />
              )}
            </span>
            <span className="min-w-0">
              <span className="block leading-tight font-medium">
                {alert === "resolved" ? "SF-142 resolved" : "New issue SF-142"}
              </span>
              <span className="text-muted-foreground block leading-tight">
                <span className="max-md:hidden">
                  {alert === "resolved"
                    ? "Slack #storefront-alerts · just now"
                    : "Sent to Slack #storefront-alerts"}
                </span>
                <span className="md:hidden">Slack #storefront-alerts</span>
              </span>
            </span>
          </div>
        </CardHeader>
        <CardContent className="grid gap-6">
          <StatStrip>
            <Stat label="p50 latency" value="42ms" hint="last 24h" />
            <Stat
              label="error rate"
              value={faulted ? "2.1%" : "0.4%"}
              tone={faulted ? "destructive" : "success"}
              hint={faulted ? "3 of 143 requests" : "last 24h"}
            />
            <Stat label="requests/min" value="1.2k" />
            <Stat
              label="open issues"
              value={faulted ? "1" : "0"}
              tone={faulted ? "destructive" : "success"}
            />
          </StatStrip>
          {/* The issue the exception opened, the way the issues list shows
              it: open while the line is held, resolved once it clears. */}
          <div
            className={cn(
              "flex items-center justify-between gap-3 rounded-md border px-3 py-2 text-xs transition-colors duration-500",
              faulted ? "border-danger/40 bg-danger/5" : "bg-muted/30",
            )}
          >
            <div className="flex min-w-0 items-center gap-3">
              <span className="shrink-0 font-mono font-semibold">SF-142</span>
              <span className="truncate">
                NoMethodError in WidgetsController#index
              </span>
            </div>
            <div className="text-muted-foreground flex shrink-0 items-center gap-3 font-mono">
              <span className="hidden sm:inline">3 events</span>
              <IssueStatusBadge status={faulted ? "open" : "resolved"} />
            </div>
          </div>
          <Timeline
            entries={entries}
            total={90}
            stages={{ action: 66, render: 24 }}
          />
        </CardContent>
      </Card>
    </section>
  )
}
