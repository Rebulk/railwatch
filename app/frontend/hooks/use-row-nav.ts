import { useEffect, useRef, useState } from "react"

import { ignorePageShortcut } from "@/lib/keyboard"

const navigators = new Map<symbol, () => void>()
let activeNavigator: symbol | undefined

export interface RowNavOptions<T> {
  rows: T[]
  rowKey: (row: T) => string | number
  onOpen: (row: T, opts?: { newTab?: boolean }) => void
  enabled?: boolean
}

// j/k highlight a row, Enter opens it (onOpen), "o" opens it in a new tab
// (onOpen with newTab: true), Esc clears the highlight, and "/" focuses the
// page's FilterBar input (matched by `[data-filter-bar-input]`) if present.
// Ignored while focus is in a form field or a modifier key is held. Backs
// `DataTable`'s `keyboardNav` prop; extracted here so every list page shares
// one implementation.
export function useRowNav<T>({
  rows,
  rowKey,
  onOpen,
  enabled = true,
}: RowNavOptions<T>) {
  const [highlighted, setHighlighted] = useState<string | number | null>(null)
  const [identity] = useState(() => Symbol("row-nav"))
  function activate() {
    if (!enabled || activeNavigator === identity) return
    if (activeNavigator) navigators.get(activeNavigator)?.()
    activeNavigator = identity
  }

  useEffect(() => {
    if (!enabled) return
    navigators.set(identity, () => setHighlighted(null))
    activeNavigator ??= identity
    return () => {
      navigators.delete(identity)
      if (activeNavigator === identity)
        activeNavigator = navigators.keys().next().value
    }
  }, [enabled, identity])

  const rowsRef = useRef(rows)
  const rowKeyRef = useRef(rowKey)
  const onOpenRef = useRef(onOpen)
  useEffect(() => {
    rowsRef.current = rows
    rowKeyRef.current = rowKey
    onOpenRef.current = onOpen
  })

  useEffect(() => {
    if (!enabled) return

    function onKeyDown(event: KeyboardEvent) {
      if (activeNavigator !== identity || ignorePageShortcut(event)) return

      if (event.key === "/") {
        const input = document.querySelector<HTMLElement>(
          "[data-filter-bar-input]",
        )
        if (input) {
          event.preventDefault()
          input.focus()
        }
        return
      }

      const currentRows = rowsRef.current
      const key = rowKeyRef.current
      const index = currentRows.findIndex((r) => key(r) === highlighted)

      if (event.key === "j") {
        if (currentRows.length === 0) return
        event.preventDefault()
        const next = Math.min(index + 1, currentRows.length - 1)
        setHighlighted(key(currentRows[next]))
      } else if (event.key === "k") {
        if (currentRows.length === 0) return
        event.preventDefault()
        const prev = index < 0 ? 0 : Math.max(index - 1, 0)
        setHighlighted(key(currentRows[prev]))
      } else if (event.key === "Enter") {
        if (index >= 0) {
          event.preventDefault()
          onOpenRef.current(currentRows[index])
        }
      } else if (event.key === "o") {
        if (index >= 0) {
          event.preventDefault()
          onOpenRef.current(currentRows[index], { newTab: true })
        }
      } else if (event.key === "Escape") {
        setHighlighted(null)
      }
    }

    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [highlighted, enabled, identity])

  return { highlighted, setHighlighted, activate }
}
