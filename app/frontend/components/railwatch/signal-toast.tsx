import { X } from "lucide-react"
import { toast } from "sonner"

import { cn } from "@/lib/utils"

// Notices spoken in the signal vocabulary the rest of the UI uses. The
// aspect carries the meaning, so there is no icon to interpret: green is
// clear (done, saved, sent), amber is caution (something to look at, still
// safe), red is stop (this failed). The head sits at the left of the card
// like a lineside signal; the lit lamp is the only colour on the card.
export type ToastAspect = "clear" | "caution" | "stop"

const LAMP_CLASS: Record<ToastAspect, string> = {
  stop: "bg-danger",
  caution: "bg-warning",
  clear: "bg-live",
}
const LAMP_ORDER: ToastAspect[] = ["stop", "caution", "clear"]

// Clear notices leave on their own; the line is clear and there is nothing
// to act on. Caution and stop wait to be read.
const DURATION: Record<ToastAspect, number> = {
  clear: 4000,
  caution: 8000,
  stop: Infinity,
}

function Head({ aspect }: { aspect: ToastAspect }) {
  return (
    <span
      aria-hidden
      className="border-foreground/30 bg-background/60 inline-flex w-3 shrink-0 flex-col items-center justify-between rounded-full border px-px py-1"
      style={{ height: 30 }}
    >
      {LAMP_ORDER.map((lamp) => (
        <span key={lamp} className="relative inline-flex size-2">
          {lamp === aspect && (
            <span
              className={cn(
                "absolute inline-flex h-full w-full rounded-full opacity-40 blur-[2px]",
                LAMP_CLASS[lamp],
              )}
            />
          )}
          <span
            className={cn(
              "relative inline-flex size-2 rounded-full",
              lamp === aspect ? LAMP_CLASS[lamp] : "bg-neutral-400/15",
            )}
          />
        </span>
      ))}
    </span>
  )
}

// The card itself. `onDismiss` is what the X does; the marketing hero
// renders one with no dismiss as a static example.
export function SignalCard({
  aspect,
  title,
  description,
  onDismiss,
  className,
}: {
  aspect: ToastAspect
  title: string
  description?: string
  onDismiss?: () => void
  className?: string
}) {
  const role = aspect === "stop" ? "alert" : "status"
  return (
    <div
      role={onDismiss ? role : undefined}
      data-aspect={aspect}
      className={cn(
        "bg-popover text-popover-foreground flex w-full items-start gap-3 rounded-lg border px-3.5 py-3 shadow-lg md:w-[360px]",
        className,
      )}
    >
      <Head aspect={aspect} />
      <div className="min-w-0 flex-1 pt-0.5">
        <p className="text-sm leading-snug font-medium">{title}</p>
        {description && (
          <p className="text-muted-foreground mt-0.5 text-xs leading-relaxed">
            {description}
          </p>
        )}
      </div>
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          aria-label="Dismiss"
          className="text-muted-foreground hover:text-foreground -mt-0.5 -mr-1 rounded p-1"
        >
          <X className="size-3.5" />
        </button>
      )}
    </div>
  )
}

export function signalToast(
  aspect: ToastAspect,
  title: string,
  description?: string,
) {
  return toast.custom(
    (id) => (
      <SignalCard
        aspect={aspect}
        title={title}
        description={description}
        onDismiss={() => toast.dismiss(id)}
      />
    ),
    { duration: DURATION[aspect], unstyled: true },
  )
}
