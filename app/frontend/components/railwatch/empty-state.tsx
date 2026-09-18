import { type LucideIcon } from "lucide-react"
import { type ReactNode, useId } from "react"

import { cn } from "@/lib/utils"

// A stretch of track behind the message: two rails and a run of ties. Two
// masks shape it. A horizontal one fades the ends so the line runs off the
// edge of the panel rather than stopping at it, and a radial one dissolves
// the middle so the message sits in a clear pocket while the rails stay
// legible on either side. The pocket is narrower below md so a phone card
// still shows a good run of track on each side of the message.
export function Track({ className }: { className?: string }) {
  const id = useId()
  return (
    <svg
      aria-hidden
      className={cn(
        "text-foreground/35 dark:text-foreground/40 pointer-events-none absolute inset-x-0 top-1/2 h-12 w-full -translate-y-1/2",
        "[mask-composite:intersect]",
        "[mask-image:linear-gradient(to_right,transparent,black_10%,black_90%,transparent),radial-gradient(ellipse_200px_160%_at_50%_50%,transparent_20%,black_100%)]",
        "md:[mask-image:linear-gradient(to_right,transparent,black_10%,black_90%,transparent),radial-gradient(ellipse_300px_160%_at_50%_50%,transparent_35%,black_100%)]",
        className,
      )}
      preserveAspectRatio="none"
    >
      <defs>
        <pattern id={id} width="22" height="48" patternUnits="userSpaceOnUse">
          <rect x="9" y="9" width="4" height="30" rx="1" fill="currentColor" />
        </pattern>
      </defs>
      <rect width="100%" height="100%" fill={`url(#${id})`} />
      <rect y="16" width="100%" height="2.5" fill="currentColor" />
      <rect y="29.5" width="100%" height="2.5" fill="currentColor" />
    </svg>
  )
}

export type SignalAspect = "clear" | "caution" | "stop"

const ASPECT_CLASS: Record<SignalAspect, string> = {
  clear: "text-live",
  caution: "text-warning",
  stop: "text-danger",
}

// Lamps in their real order on a three-aspect head: stop on top, caution in
// the middle, clear at the bottom.
const LAMP_Y: Record<SignalAspect, number> = { stop: 8, caution: 17, clear: 26 }
const LAMP_ORDER: SignalAspect[] = ["stop", "caution", "clear"]

// A lineside signal standing just past the pocket, on the right. The post
// and hood take the track's ink; the one lit aspect uses the status
// vocabulary the rest of the UI already speaks (green = clear, amber =
// caution, rose = stop). An empty table is a clear line, so that is the
// default; pages whose empty state is a filter miss pass "caution".
export function Signal({
  aspect,
  className,
}: {
  aspect: SignalAspect
  className?: string
}) {
  return (
    <svg
      aria-hidden
      viewBox="0 0 20 64"
      className={cn(
        "pointer-events-none absolute top-1/2 h-16 w-5 -translate-y-[calc(50%+8px)]",
        "left-[calc(50%+100px)] md:left-[calc(50%+150px)]",
        className,
      )}
    >
      <g className="text-foreground/35 dark:text-foreground/40">
        <rect x="9" y="33" width="2" height="26" rx="1" fill="currentColor" />
        <rect x="5" y="58" width="10" height="2" rx="1" fill="currentColor" />
        <rect
          x="4.75"
          y="1.75"
          width="10.5"
          height="31.5"
          rx="5.25"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
        />
      </g>
      {LAMP_ORDER.map((lamp) =>
        lamp === aspect ? (
          <g key={lamp} className={ASPECT_CLASS[lamp]} data-lamp={lamp}>
            <circle
              cx="10"
              cy={LAMP_Y[lamp]}
              r="6"
              fill="currentColor"
              opacity="0.2"
              className="blur-[2px]"
            />
            <circle cx="10" cy={LAMP_Y[lamp]} r="3" fill="currentColor" />
          </g>
        ) : (
          <circle
            key={lamp}
            cx="10"
            cy={LAMP_Y[lamp]}
            r="3"
            className="text-foreground/15"
            fill="currentColor"
          />
        ),
      )}
    </svg>
  )
}

// Empty state for tables and panels: the icon, title, optional description
// and action, set in the clear pocket of a track that runs behind them,
// with a signal beside the line showing the aspect.
export function EmptyState({
  icon: Icon,
  title,
  description,
  action,
  signal = "clear",
  className,
}: {
  icon?: LucideIcon
  title: ReactNode
  description?: ReactNode
  action?: ReactNode
  signal?: SignalAspect
  className?: string
}) {
  return (
    <div
      className={cn(
        "relative flex min-h-48 items-center justify-center overflow-hidden px-4 py-8 text-center",
        className,
      )}
      aria-live="polite"
    >
      <Track />
      <Signal aspect={signal} />
      <div className="relative flex max-w-xs flex-col items-center gap-1.5">
        {Icon && (
          <span className="bg-muted text-muted-foreground mb-1 flex size-9 items-center justify-center rounded-md">
            <Icon className="size-4" />
          </span>
        )}
        <span className="text-sm font-medium">{title}</span>
        {description && (
          <span className="text-muted-foreground text-xs leading-relaxed">
            {description}
          </span>
        )}
        {action && <div className="mt-2">{action}</div>}
      </div>
    </div>
  )
}
