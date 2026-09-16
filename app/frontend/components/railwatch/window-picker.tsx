import { CalendarClock } from "lucide-react"
import { useState } from "react"

import { Segmented, SegmentedItem } from "@/components/railwatch/segmented"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover"
import { WINDOWS, useWindow } from "@/hooks/use-window"

function toLocalInputValue(iso: string) {
  const d = new Date(iso)
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function startOfDay(d: Date) {
  const x = new Date(d)
  x.setHours(0, 0, 0, 0)
  return x
}

const PRESETS: { label: string; range: () => [Date, Date] }[] = [
  { label: "Today", range: () => [startOfDay(new Date()), new Date()] },
  {
    label: "Yesterday",
    range: () => {
      const end = startOfDay(new Date())
      const start = startOfDay(new Date(end.getTime() - 24 * 60 * 60 * 1000))
      return [start, end]
    },
  },
  {
    label: "This week",
    range: () => {
      const start = startOfDay(new Date())
      start.setDate(start.getDate() - start.getDay())
      return [start, new Date()]
    },
  },
]

// Fixed 1h–30d toggle plus a "Custom" popover with quick presets and
// from/to datetime-local inputs; both write through useWindow().
export function WindowPicker() {
  const { window, from, to, set, setRange, label } = useWindow()
  const [open, setOpen] = useState(false)
  const [fromInput, setFromInput] = useState(() =>
    toLocalInputValue(
      from ?? new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString(),
    ),
  )
  const [toInput, setToInput] = useState(() =>
    toLocalInputValue(to ?? new Date().toISOString()),
  )

  const applyRange = (f: Date, t: Date) => {
    setFromInput(toLocalInputValue(f.toISOString()))
    setToInput(toLocalInputValue(t.toISOString()))
    setRange(f.toISOString(), t.toISOString())
    setOpen(false)
  }

  const applyInputs = () => {
    const f = new Date(fromInput)
    const t = new Date(toInput)
    if (!Number.isNaN(f.getTime()) && !Number.isNaN(t.getTime()))
      applyRange(f, t)
  }

  return (
    <Segmented>
      {WINDOWS.map((w) => (
        <SegmentedItem
          key={w.value}
          active={window === w.value}
          onClick={() => set(w.value)}
          aria-label={w.label}
        >
          {w.value}
        </SegmentedItem>
      ))}
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <SegmentedItem
            active={window === "custom"}
            onClick={() => setOpen(true)}
            aria-label="Custom range"
            className="px-2"
          >
            <CalendarClock className="size-3" />
            <span className="hidden sm:inline">
              {window === "custom" ? label : "Custom"}
            </span>
          </SegmentedItem>
        </PopoverTrigger>
        <PopoverContent className="w-72" align="end">
          <div className="flex flex-col gap-3">
            <div className="flex flex-wrap gap-1">
              {PRESETS.map((preset) => (
                <Button
                  key={preset.label}
                  type="button"
                  variant="outline"
                  size="sm"
                  onClick={() => {
                    const [f, t] = preset.range()
                    applyRange(f, t)
                  }}
                >
                  {preset.label}
                </Button>
              ))}
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="window-picker-from" className="text-xs">
                From
              </Label>
              <Input
                id="window-picker-from"
                type="datetime-local"
                value={fromInput}
                onChange={(e) => setFromInput(e.target.value)}
              />
              <Label htmlFor="window-picker-to" className="text-xs">
                To
              </Label>
              <Input
                id="window-picker-to"
                type="datetime-local"
                value={toInput}
                onChange={(e) => setToInput(e.target.value)}
              />
            </div>
            <Button type="button" size="sm" onClick={applyInputs}>
              Apply
            </Button>
          </div>
        </PopoverContent>
      </Popover>
    </Segmented>
  )
}
