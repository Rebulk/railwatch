import type { ReactNode } from "react"
import { useEffect, useRef } from "react"

import { useChartHover } from "@/components/railwatch/chart-hover"
import { EmptyState } from "@/components/railwatch/empty-state"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { useRowNav } from "@/hooks/use-row-nav"
import { cn } from "@/lib/utils"

const INTERACTIVE_TARGET =
  'a, button, input, select, textarea, [role="button"], [role="link"], [contenteditable="true"]'

function isInteractiveTarget(target: EventTarget | null) {
  return target instanceof Element && target.closest(INTERACTIVE_TARGET)
}

export interface Column<T> {
  key: string
  header: ReactNode
  cell: (row: T) => ReactNode
  className?: string
  align?: "left" | "right"
  // Hide this column below the md breakpoint. Phones get the columns that
  // identify the row and the one number that matters; the rest come back
  // on wider screens. Every page marks its own secondary columns.
  hideOnMobile?: boolean
  // The column that identifies the row (route, SQL, job class). It takes
  // whatever width the numeric columns leave over and truncates, so the
  // table fits its container instead of forcing a sideways scroll.
  grow?: boolean
}

export interface KeyboardNav<T> {
  onOpen: (row: T, opts?: { newTab?: boolean }) => void
  enabled?: boolean
  // Fires whenever j/k/Esc change the highlighted row, so a page can drive
  // other row-scoped shortcuts (e.g. issues' r/i/a) off the same state.
  onHighlightChange?: (row: T | null) => void
}

export function DataTable<T>({
  rows,
  columns,
  rowKey,
  empty = "Nothing here yet.",
  onRowClick,
  keyboardNav,
  hoverKey,
  rowClassName,
  className,
}: {
  rows: T[]
  columns: Column<T>[]
  rowKey: (row: T) => string | number
  empty?: ReactNode
  onRowClick?: (row: T) => void
  keyboardNav?: KeyboardNav<T>
  // Per-row tint for a row whose own state matters (a crashed session), on
  // top of the highlight/hover states below.
  rowClassName?: (row: T) => string | undefined
  // Links rows to a chart via ChartHoverProvider: hovering a row sets this
  // key (e.g. the row's group_hash) as the shared hovered key, and rows
  // whose key matches an externally-hovered chart point get `data-hovered`.
  hoverKey?: (row: T) => string | undefined
  className?: string
}) {
  const { highlighted, activate } = useRowNav({
    rows,
    rowKey,
    onOpen: keyboardNav?.onOpen ?? (() => undefined),
    enabled: Boolean(keyboardNav) && keyboardNav?.enabled !== false,
  })

  const rowRefs = useRef(new Map<string | number, HTMLTableRowElement>())

  useEffect(() => {
    if (highlighted == null) return
    rowRefs.current.get(highlighted)?.scrollIntoView({ block: "nearest" })
  }, [highlighted])

  useEffect(() => {
    if (!keyboardNav?.onHighlightChange) return
    const row = rows.find((r) => rowKey(r) === highlighted) ?? null
    keyboardNav.onHighlightChange(row)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [highlighted])

  const { hoveredKey, setHoveredKey } = useChartHover()
  const colClass = (c: Column<T>) =>
    cn(
      c.align === "right" && "text-right",
      c.hideOnMobile && "hidden md:table-cell",
      c.grow && "w-full max-w-0 truncate",
      c.className,
    )

  return (
    <div
      tabIndex={keyboardNav && keyboardNav.enabled !== false ? 0 : undefined}
      onFocusCapture={activate}
      onPointerDownCapture={activate}
      className={cn(
        "bg-card -mx-3 overflow-x-auto border-y md:mx-0 md:rounded-lg md:border",
        className,
      )}
    >
      <Table>
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            {columns.map((c) => (
              <TableHead key={c.key} className={colClass(c)}>
                {c.header}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.length === 0 && (
            <TableRow>
              <TableCell
                colSpan={columns.length}
                className="p-0 whitespace-normal"
              >
                {typeof empty === "string" ? (
                  <EmptyState title={empty} />
                ) : (
                  <div className="text-muted-foreground min-h-24 text-center">
                    {empty}
                  </div>
                )}
              </TableCell>
            </TableRow>
          )}
          {rows.map((row) => {
            const key = rowKey(row)
            const isHighlighted = Boolean(keyboardNav) && highlighted === key
            const rowHoverKey = hoverKey?.(row)
            const isHovered = rowHoverKey != null && hoveredKey === rowHoverKey
            return (
              <TableRow
                key={key}
                ref={(el) => {
                  if (el) rowRefs.current.set(key, el)
                  else rowRefs.current.delete(key)
                }}
                data-state={isHighlighted ? "highlighted" : undefined}
                data-hovered={isHovered || undefined}
                className={cn(
                  onRowClick && "cursor-pointer",
                  rowClassName?.(row),
                  isHighlighted &&
                    "bg-accent shadow-[inset_2px_0_0_0_var(--primary)]",
                  isHovered && !isHighlighted && "bg-accent/50",
                )}
                onClick={
                  onRowClick
                    ? (event) => {
                        if (!isInteractiveTarget(event.target)) onRowClick(row)
                      }
                    : undefined
                }
                onMouseEnter={
                  rowHoverKey ? () => setHoveredKey(rowHoverKey) : undefined
                }
                onMouseLeave={
                  rowHoverKey ? () => setHoveredKey(null) : undefined
                }
              >
                {columns.map((c) => (
                  <TableCell
                    key={c.key}
                    className={cn(
                      "py-1.5 text-xs",
                      c.align === "right" && "font-mono tabular-nums",
                      colClass(c),
                    )}
                  >
                    {c.cell(row)}
                  </TableCell>
                ))}
              </TableRow>
            )
          })}
        </TableBody>
      </Table>
    </div>
  )
}
