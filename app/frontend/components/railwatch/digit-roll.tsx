import { useEffect, useRef } from "react"

import { cn } from "@/lib/utils"

// A number whose digits roll when it changes: the digits that actually
// changed slide up (or down, when the number falls) to their new glyph and
// the rest of the number stays exactly where it is.
//
// This is motion on an operational dashboard, which is a thing to be
// careful with rather than a thing to sprinkle around -- see the gates on
// `Stat`'s rolling path, which is what decides whether this component is
// rendered at all. What this component owns is the part of the contract
// that no caller can get right by itself:
//
//   * the roll is 300ms, so it is over long before the next update can
//     arrive (see ROLL_MIN_INTERVAL_MS) and the strip is never in motion
//     for more than ~15% of the time;
//   * updates are coalesced to one roll every 2s. An update that lands
//     inside that window is remembered, not painted, and the roll that
//     follows goes straight to the newest value. A roll is never
//     interrupted, because an animation that never finishes is worse than
//     no animation at all;
//   * the first paint is static. A page that opens, or one that is
//     navigated back to, shows its numbers rather than animating up to
//     them.
//
// The cells are built by hand rather than rendered, because they are keyed
// by place value and animated with the Web Animations API, and neither of
// those survives React re-rendering the digits underneath them. They are
// decoration -- whoever renders this is expected to hide it from assistive
// tech and put the number in a text node beside it (`Stat` does).

// The one switch. Flip this to false and every rolling number in the app --
// the dashboard's stats, and whatever the landing page does with the same
// component -- becomes a plain static number.
export const DIGIT_ROLL_ENABLED = true

export const ROLL_DURATION_MS = 300
export const ROLL_EASING = "cubic-bezier(.22, 1, .36, 1)"
export const ROLL_MIN_INTERVAL_MS = 2_000

// Fixed em heights on every piece, so a roll cannot change the line box and
// the strip below the number cannot be pushed around by it.
const CELL_CLASS =
  "inline-block h-[1.15em] overflow-hidden leading-[1.15em] align-top"
const SEPARATOR_CLASS =
  "inline-block h-[1.15em] overflow-visible leading-[1.15em] align-top text-center"
const STRIP_CLASS = "block will-change-transform"
const SLOT_CLASS = "block h-[1.15em] leading-[1.15em]"
const SUFFIX_CLASS = "inline-block h-[1.15em] leading-[1.15em]"

type Direction = -1 | 0 | 1

// A thousands separator (or a decimal point, or a minus sign) never rolls,
// so it is a plain glyph rather than a two-slot stack.
interface SeparatorCell {
  separator: true
  el: HTMLSpanElement
  char: string | null
}

interface DigitCell {
  separator: false
  el: HTMLSpanElement
  strip: HTMLSpanElement
  top: HTMLSpanElement
  bottom: HTMLSpanElement
  animation: Animation | null
  char: string | null
}

type Cell = SeparatorCell | DigitCell

function span(className: string) {
  const el = document.createElement("span")
  el.className = className
  return el
}

// "412,908ms" -> { digits: "412,908", suffix: "ms" }. The unit is one glyph
// run at the end of the number that nothing ever moves.
function split(formatted: string) {
  let end = formatted.length
  while (end > 0 && !/[0-9]/.test(formatted[end - 1])) end--
  return { digits: formatted.slice(0, end), suffix: formatted.slice(end) }
}

function makeCell(separator: boolean): Cell {
  const el = span(separator ? SEPARATOR_CLASS : CELL_CLASS)
  if (separator) return { separator: true, el, char: null }
  const strip = span(STRIP_CLASS)
  const top = span(SLOT_CLASS)
  const bottom = span(SLOT_CLASS)
  strip.append(top, bottom)
  el.append(strip)
  return {
    separator: false,
    el,
    strip,
    top,
    bottom,
    animation: null,
    char: null,
  }
}

// Cells are keyed by distance from the right of the number, so a digit keeps
// its identity -- its place value -- even when the number gains a digit:
// 999 -> 1,000 leaves keys 0,1,2 rolling 9 -> 0 and simply inserts key 3
// (the comma) and key 4 (the 1). No re-keying, no cascade, and the digits
// that did not change never move.
function createRoll(
  host: HTMLElement,
  { durationMs, easing }: { durationMs: number; easing: string },
) {
  const cells = new Map<number, Cell>()
  let order = ""

  // Collapse a cell back to the single digit that is showing. The glyph it
  // rolled away from is out of view but still in the DOM, and a selection
  // (or a copy) would otherwise pick it up.
  function settle(cell: DigitCell, char: string) {
    cell.animation?.cancel()
    cell.animation = null
    cell.top.textContent = char
    cell.bottom.textContent = ""
    cell.char = char
  }

  function roll(cell: DigitCell, char: string, direction: -1 | 1) {
    // jsdom has no Web Animations API. Nothing to roll there: show the digit.
    if (typeof cell.strip.animate !== "function") {
      settle(cell, char)
      return
    }
    // Cancel, re-fill the slots, and start the new animation in one task, so
    // the browser never paints the intermediate state: an interrupted roll
    // restarts from wherever it had got to, towards the new target.
    cell.animation?.cancel()
    const from = cell.char ?? char
    if (direction > 0) {
      cell.top.textContent = from
      cell.bottom.textContent = char
    } else {
      cell.top.textContent = char
      cell.bottom.textContent = from
    }
    const keyframes =
      direction > 0
        ? [{ transform: "translateY(0)" }, { transform: "translateY(-50%)" }]
        : [{ transform: "translateY(-50%)" }, { transform: "translateY(0)" }]
    const animation = cell.strip.animate(keyframes, {
      duration: durationMs,
      easing,
      fill: "forwards",
    })
    cell.animation = animation
    cell.char = char
    animation.onfinish = () => {
      if (cell.animation === animation) settle(cell, char)
    }
  }

  function enter(cell: Cell) {
    if (typeof cell.el.animate !== "function") return
    cell.el.animate(
      [
        { opacity: 0, transform: "translateY(0.35em)" },
        { opacity: 1, transform: "none" },
      ],
      { duration: durationMs, easing },
    )
  }

  return {
    paint(formatted: string, direction: Direction) {
      const { digits, suffix } = split(formatted)
      const chars = digits.split("")
      const wanted = chars.map((char, index) => ({
        key: chars.length - 1 - index,
        char,
      }))
      const nextOrder = `${wanted.map((cell) => cell.key).join(",")}|${suffix}`
      const first = order === ""

      if (nextOrder !== order) {
        // The key set changed (the number gained or lost a digit): re-lay the
        // row, reusing every cell whose key survived.
        const fragment = document.createDocumentFragment()
        const keep = new Set<number>()
        for (const { key, char } of wanted) {
          keep.add(key)
          const separator = !/[0-9]/.test(char)
          let cell = cells.get(key)
          if (cell?.separator !== separator) {
            cell = makeCell(separator)
            cells.set(key, cell)
            if (!first && direction !== 0) enter(cell)
          }
          fragment.append(cell.el)
        }
        for (const key of [...cells.keys()])
          if (!keep.has(key)) cells.delete(key)
        host.replaceChildren(fragment)
        if (suffix) {
          const el = span(SUFFIX_CLASS)
          el.textContent = suffix
          host.append(el)
        }
        order = nextOrder
      }

      for (const { key, char } of wanted) {
        const cell = cells.get(key)
        if (!cell || cell.char === char) continue // this digit did not change
        if (cell.separator) {
          cell.el.textContent = char
          cell.char = char
        } else if (cell.char === null || direction === 0) {
          settle(cell, char)
        } else {
          roll(cell, char, direction)
        }
      }
    },

    destroy() {
      for (const cell of cells.values())
        if (!cell.separator) cell.animation?.cancel()
    },
  }
}

export function DigitRoll({
  value,
  format,
  className,
  durationMs = ROLL_DURATION_MS,
  easing = ROLL_EASING,
  minIntervalMs = ROLL_MIN_INTERVAL_MS,
}: {
  value: number
  format: (value: number) => string
  className?: string
  durationMs?: number
  easing?: string
  minIntervalMs?: number
}) {
  const hostRef = useRef<HTMLSpanElement>(null)
  const rollRef = useRef<ReturnType<typeof createRoll> | null>(null)
  // What the cells are showing, which is not `value` while an update is
  // being held back by the coalescing window.
  const shownRef = useRef(value)
  const pendingRef = useRef<number | null>(null)
  const lastRollAtRef = useRef(0)
  const timerRef = useRef<number | undefined>(undefined)
  const optionsRef = useRef({ format, durationMs, easing, minIntervalMs })
  useEffect(() => {
    optionsRef.current = { format, durationMs, easing, minIntervalMs }
  })

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const { format, durationMs, easing } = optionsRef.current
    const roll = createRoll(host, { durationMs, easing })
    rollRef.current = roll
    // Never on mount: the first paint is the number, not a roll up to it.
    roll.paint(format(shownRef.current), 0)
    return () => {
      clearTimeout(timerRef.current)
      timerRef.current = undefined
      pendingRef.current = null
      rollRef.current = null
      roll.destroy()
    }
    // Built once; every later value goes through the effect below.
  }, [])

  useEffect(() => {
    const roll = rollRef.current
    if (!roll || value === shownRef.current) return

    const apply = (next: number) => {
      lastRollAtRef.current = Date.now()
      roll.paint(
        optionsRef.current.format(next),
        next >= shownRef.current ? 1 : -1,
      )
      shownRef.current = next
    }

    const elapsed = Date.now() - lastRollAtRef.current
    const wait = optionsRef.current.minIntervalMs - elapsed
    if (wait <= 0) {
      apply(value)
      return
    }
    // Inside the window: hold this value (replacing any other one being
    // held) and let the timer already running land the newest of them. The
    // roll in flight is left alone.
    pendingRef.current = value
    timerRef.current ??= window.setTimeout(() => {
      timerRef.current = undefined
      const next = pendingRef.current
      pendingRef.current = null
      if (next !== null && next !== shownRef.current) apply(next)
    }, wait)
  }, [value])

  return <span ref={hostRef} className={cn(className)} />
}
