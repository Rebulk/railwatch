import { ArrowDown, ArrowUp } from "lucide-react"

import { cn } from "@/lib/utils"

// Clickable DataTable column header for a sortable numeric column. Dumb by
// design: the page builds the sort/dir URL with its own route helper and
// passes the click handler in.
export function SortHeader({
  label,
  active,
  dir,
  onClick,
}: {
  label: string
  active: boolean
  dir: "asc" | "desc"
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "hover:text-foreground inline-flex items-center gap-1",
        active && "text-foreground font-semibold",
      )}
    >
      {label}
      {active &&
        (dir === "asc" ? (
          <ArrowUp className="size-3" />
        ) : (
          <ArrowDown className="size-3" />
        ))}
    </button>
  )
}
