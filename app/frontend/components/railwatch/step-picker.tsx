import { ChevronDown } from "lucide-react"

import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { STEP_LABELS, useStep } from "@/hooks/use-step"
import type { Step } from "@/types"

// Bucket width for every chart on the page, next to the window picker:
// "1m", "5m", ... as a mono chip opening a menu of the widths the window
// offers. Hidden when the window offers only one.
export function StepPicker() {
  const { step, steps, set } = useStep()
  if (steps.length < 2) return null
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="outline"
          size="sm"
          className="h-8 gap-1 px-2 font-mono text-xs uppercase"
          aria-label={`Chart buckets: ${STEP_LABELS[step]}`}
        >
          <span className="text-muted-foreground normal-case">per</span>
          {step}
          <ChevronDown className="text-muted-foreground size-3" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-44">
        <DropdownMenuLabel className="label-caps">
          Chart buckets
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuRadioGroup
          value={step}
          onValueChange={(value) => set(value as Step)}
        >
          {steps.map((s) => (
            <DropdownMenuRadioItem key={s} value={s} className="text-xs">
              <span className="font-mono uppercase">{s}</span>
              <span className="text-muted-foreground ml-auto">
                {STEP_LABELS[s]}
              </span>
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
