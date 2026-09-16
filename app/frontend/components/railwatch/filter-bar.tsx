import { Filter as FilterIcon, Search, X } from "lucide-react"
import { useState } from "react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover"
import { parseFilter, serializeFilter } from "@/lib/filter"

export interface FilterField {
  key: string
  label: string
  options?: string[]
}

// key:value key2:value2 free text query bar: chips for parsed field tokens,
// a raw-text input for typing (Enter/blur commits), and a field/option
// autocomplete popover. Full width on phones, a search-box on desktop.
export function FilterBar({
  value,
  fields,
  onChange,
  placeholder = "Filter...",
}: {
  value: string
  fields: FilterField[]
  onChange: (query: string) => void
  placeholder?: string
}) {
  const [draft, setDraft] = useState(value)
  const [open, setOpen] = useState(false)
  // Re-sync the draft when `value` changes from outside (e.g. a chip removal
  // round-tripping through the server, or browser back/forward) without an
  // effect: https://react.dev/learn/you-might-not-need-an-effect
  const [syncedValue, setSyncedValue] = useState(value)
  if (value !== syncedValue) {
    setSyncedValue(value)
    setDraft(value)
  }
  const parsed = parseFilter(value)

  const removeField = (key: string) => {
    const next = { ...parsed.fields }
    delete next[key]
    const q = serializeFilter({ text: parsed.text, fields: next })
    setDraft(q)
    onChange(q)
  }

  const applyToken = (key: string, val: string) => {
    const q = serializeFilter({
      text: parsed.text,
      fields: { ...parsed.fields, [key]: val },
    })
    setDraft(q)
    onChange(q)
    setOpen(false)
  }

  const startToken = (key: string) => {
    setDraft((d) => `${d}${d && !d.endsWith(" ") ? " " : ""}${key}:`)
    setOpen(false)
  }

  const commit = () => onChange(draft)

  return (
    <div className="flex flex-wrap items-center gap-2">
      <div className="bg-card focus-within:border-ring flex h-8 min-w-0 flex-1 items-center gap-1.5 rounded-md border px-2 md:max-w-md md:flex-none md:basis-80">
        <Search className="text-muted-foreground size-3.5 shrink-0" />
        {Object.entries(parsed.fields).map(([key, val]) => (
          <Badge
            key={key}
            variant="secondary"
            className="shrink-0 gap-1 rounded-sm px-1.5 font-mono text-[10px]"
          >
            {key}:{val}
            <button
              type="button"
              onClick={() => removeField(key)}
              className="hover:text-destructive"
              aria-label={`Remove ${key} filter`}
            >
              <X className="size-3" />
            </button>
          </Badge>
        ))}
        <input
          data-filter-bar-input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && commit()}
          onBlur={commit}
          placeholder={placeholder}
          className="placeholder:text-muted-foreground min-w-0 flex-1 bg-transparent font-mono text-xs outline-none"
        />
        <kbd className="bg-muted text-muted-foreground hidden rounded px-1 font-mono text-[10px] md:inline">
          /
        </kbd>
      </div>
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="h-8 px-2"
            aria-label="Add filter"
          >
            <FilterIcon className="size-3.5" />
          </Button>
        </PopoverTrigger>
        <PopoverContent className="w-56 p-0" align="start">
          <Command>
            <CommandList>
              <CommandEmpty>No fields.</CommandEmpty>
              {fields.map((f) =>
                f.options ? (
                  <CommandGroup key={f.key} heading={f.label}>
                    {f.options.map((opt) => (
                      <CommandItem
                        key={opt}
                        onSelect={() => applyToken(f.key, opt)}
                      >
                        {opt}
                      </CommandItem>
                    ))}
                  </CommandGroup>
                ) : (
                  <CommandGroup key={f.key} heading={f.label}>
                    <CommandItem onSelect={() => startToken(f.key)}>
                      {f.key}:…
                    </CommandItem>
                  </CommandGroup>
                ),
              )}
            </CommandList>
          </Command>
        </PopoverContent>
      </Popover>
    </div>
  )
}
