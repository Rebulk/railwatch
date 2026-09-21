import { usePage } from "@inertiajs/react"
import type { ReactNode } from "react"

import type { SharedProps } from "@/types"

import { LiveToggle } from "./live-toggle"
import { StepPicker } from "./step-picker"
import { WindowPicker } from "./window-picker"

// Page title row. On phones the controls drop under the title and wrap onto
// as many rows as they need, so nothing is clipped at the viewport edge.
export function PageHeader({
  title,
  description,
  actions,
  withWindow = true,
}: {
  title: ReactNode
  description?: ReactNode
  actions?: ReactNode
  withWindow?: boolean
}) {
  const { environment } = usePage<SharedProps>().props
  return (
    <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between md:gap-4">
      <div className="min-w-0">
        <h1 className="truncate text-xl font-semibold tracking-tight md:text-2xl">
          {title}
        </h1>
        {description && (
          <p className="text-muted-foreground mt-0.5 text-sm">{description}</p>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-2 md:shrink-0 md:justify-end">
        {environment && <LiveToggle environmentId={environment.id} />}
        {actions}
        {withWindow && <StepPicker />}
        {withWindow && <WindowPicker />}
      </div>
    </div>
  )
}
