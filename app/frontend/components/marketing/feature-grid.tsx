import { useState } from "react"

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog"

// Each card shows a crop of the real page behind the feature, taken from a
// week of a demo storefront's telemetry; clicking it opens the full page.
// The images live in public/marketing so their URLs stay stable across
// asset digests, like the social preview image.
interface Feature {
  title: string
  description: string
  image: string
  alt: string
}

const FEATURES: Feature[] = [
  {
    title: "Requests",
    description:
      "Every route's throughput, latency percentiles, and status codes, down to a single request's waterfall.",
    image: "requests",
    alt: "The Requests page: throughput and latency charts over a table of every route with its 2xx, 4xx, 5xx counts, error rate, and p95",
  },
  {
    title: "Jobs & scheduled tasks",
    description:
      "Queue depth, retries, and run history for Active Job and your recurring tasks.",
    image: "jobs",
    alt: "The Jobs page: attempts per hour split into processed and failed, a queue table with average wait, and the most recent runs",
  },
  {
    title: "Queries & N+1s",
    description:
      "Slow queries and N+1 patterns grouped by source location, not buried in a log line.",
    image: "queries",
    alt: "The Queries page: two N+1 patterns with a suggested fix and the source line, above every SQL shape ranked by count and p95",
  },
  {
    title: "Exceptions → Issues",
    description:
      "Exceptions are grouped into Issues that track occurrences, assignees, and status over time.",
    image: "issues",
    alt: "An issue page: a resolved NoMethodError with the raising line of source highlighted, its breadcrumbs, and the alerts it sent",
  },
  {
    title: "Inertia visits",
    description:
      "Page-by-page render and payload size, so a slow visit is obvious before support tickets show up.",
    image: "visits",
    alt: "The Inertia visits page: p75 web vitals, visits per hour, and a table of components with visit count, LCP, INP, and p95",
  },
  {
    title: "Deploy comparison",
    description:
      "Every chart is annotated with deploys, so a regression points straight at the change that caused it.",
    image: "deploys",
    alt: "A deploy page: the commits it shipped, its crash-free rate, and request p95, error rate, and job failures for the hour before and after",
  },
  {
    title: "Alerts",
    description:
      "Threshold and issue alerts delivered where your team already works.",
    image: "alerts",
    alt: "The Alerts page: new, resolved, and threshold alerts delivered to Slack and email, newest first",
  },
  {
    title: "MCP / API",
    description:
      "A JSON-RPC MCP endpoint and a token-authenticated API, so your AI assistant can query production directly.",
    image: "mcp",
    alt: "A request page with its Copy as Markdown button: the same timeline an assistant reads over MCP",
  },
]

export function FeatureGrid() {
  const [open, setOpen] = useState<Feature | null>(null)

  return (
    <section className="mx-auto max-w-5xl px-6 pb-16">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {FEATURES.map((feature) => {
          const { title, description, image, alt } = feature
          return (
            <div
              key={title}
              className="bg-card flex flex-col overflow-hidden rounded-lg border"
            >
              <button
                type="button"
                onClick={() => setOpen(feature)}
                className="group relative aspect-[4/3] w-full cursor-zoom-in overflow-hidden border-b bg-[#020618] text-left"
                aria-label={`Open a full screenshot of ${title}`}
              >
                <img
                  src={`/marketing/${image}.webp`}
                  alt={alt}
                  loading="lazy"
                  width={1200}
                  height={900}
                  className="h-full w-full object-cover object-top transition-transform duration-500 ease-out group-hover:scale-[1.03] motion-reduce:transition-none"
                />
              </button>
              <div className="space-y-1 px-4 py-3">
                <h3 className="text-sm font-semibold">{title}</h3>
                <p className="text-muted-foreground text-[13px] leading-snug">
                  {description}
                </p>
              </div>
            </div>
          )
        })}
      </div>

      <Dialog open={open !== null} onOpenChange={(v) => !v && setOpen(null)}>
        <DialogContent className="bg-background max-h-[92vh] w-[min(96vw,1400px)] gap-0 overflow-hidden p-0 sm:max-w-none">
          {open && (
            <>
              <div className="border-b px-5 py-3">
                <DialogTitle className="text-base">{open.title}</DialogTitle>
                <DialogDescription>{open.description}</DialogDescription>
              </div>
              <img
                src={`/marketing/${open.image}-full.webp`}
                alt={open.alt}
                width={1920}
                height={1200}
                className="block max-h-[calc(92vh-4.5rem)] w-full object-contain object-top"
              />
            </>
          )}
        </DialogContent>
      </Dialog>
    </section>
  )
}
