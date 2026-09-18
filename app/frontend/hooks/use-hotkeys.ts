import { useEffect, useRef } from "react"

type HotkeyMap = Record<string, () => void>

const CHORD_TIMEOUT_MS = 800

// Tiny keyboard shortcut hook supporting single keys ("?") and two-key
// chords ("g d") without pulling in a dependency. Ignores keystrokes while
// focus is in a form field, and while a modifier key is held.
export function useHotkeys(map: HotkeyMap) {
  const mapRef = useRef(map)
  useEffect(() => {
    mapRef.current = map
  })

  const pending = useRef<string | null>(null)
  const timer = useRef<number | undefined>(undefined)

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement
      if (
        target.tagName === "INPUT" ||
        target.tagName === "TEXTAREA" ||
        target.tagName === "SELECT" ||
        target.isContentEditable
      ) {
        return
      }
      if (event.metaKey || event.ctrlKey || event.altKey) return

      if (pending.current) {
        const combo = `${pending.current} ${event.key}`
        window.clearTimeout(timer.current)
        pending.current = null
        if (mapRef.current[combo]) {
          event.preventDefault()
          mapRef.current[combo]()
          return
        }
      }

      if (mapRef.current[event.key]) {
        event.preventDefault()
        mapRef.current[event.key]()
        return
      }

      if (event.key === "g") {
        pending.current = "g"
        timer.current = window.setTimeout(() => {
          pending.current = null
        }, CHORD_TIMEOUT_MS)
      }
    }

    document.addEventListener("keydown", onKeyDown)
    return () => {
      document.removeEventListener("keydown", onKeyDown)
      window.clearTimeout(timer.current)
    }
  }, [])
}
