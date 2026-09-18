// A block of the marketing page fading and rising into place on load. Each
// gets a step so the nav, hero, product preview, and the sections below
// arrive one after another rather than all at once. The animation runs
// once, from the element's first paint, and prefers-reduced-motion gets
// the finished state with no motion at all.
import type { ReactNode } from "react"

import { cn } from "@/lib/utils"

const STEP_MS = 110

export function Reveal({
  step = 0,
  className,
  children,
}: {
  step?: number
  className?: string
  children: ReactNode
}) {
  return (
    <div
      className={cn(
        "motion-safe:animate-in motion-safe:fade-in motion-safe:slide-in-from-bottom-2 motion-safe:fill-mode-both motion-safe:duration-700 motion-safe:ease-out",
        className,
      )}
      style={{ animationDelay: `${step * STEP_MS}ms` }}
    >
      {children}
    </div>
  )
}
