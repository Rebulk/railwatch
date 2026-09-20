import { act, render } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { DigitRoll } from "@/components/railwatch/digit-roll"

// jsdom implements no Web Animations API at all, so the component's
// animations are recorded here instead of run. Each one can be finished on
// demand, which is what the component waits for before collapsing a rolled
// cell back to the single digit it landed on.
interface FakeAnimation {
  element: Element
  keyframes: Keyframe[]
  cancelled: boolean
  onfinish: (() => void) | null
  cancel: () => void
  finish: () => void
}

let animations: FakeAnimation[] = []

function fakeAnimate(
  this: Element,
  keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
): Animation {
  const animation: FakeAnimation = {
    element: this,
    keyframes: Array.isArray(keyframes) ? keyframes : [],
    cancelled: false,
    onfinish: null,
    cancel: () => {
      animation.cancelled = true
    },
    finish: () => animation.onfinish?.(),
  }
  animations.push(animation)
  return animation as unknown as Animation
}

// The two-slot strip inside a digit cell is the only thing that rolls; a
// cell that has just appeared (the comma and the leading 1 of 1,000) fades
// in on the cell element itself.
const rolls = () =>
  animations.filter((a) =>
    a.element.classList.contains("will-change-transform"),
  )
const entrances = () =>
  animations.filter(
    (a) => !a.element.classList.contains("will-change-transform"),
  )

function finishAll() {
  for (const animation of animations)
    if (!animation.cancelled) animation.finish()
}

const fmt = (value: number) => value.toLocaleString("en-US")

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date("2026-09-03T12:00:00.000Z"))
  animations = []
  Element.prototype.animate = fakeAnimate
})

afterEach(() => {
  vi.useRealTimers()
  delete (Element.prototype as Partial<Element>).animate
})

describe("DigitRoll", () => {
  it("paints the formatted value without animating on mount", () => {
    const { container } = render(<DigitRoll value={36051} format={fmt} />)
    expect(animations).toHaveLength(0)
    expect(container.textContent).toBe("36,051")
  })

  it("rolls only the digits that changed", () => {
    const { container, rerender } = render(
      <DigitRoll value={36051} format={fmt} />,
    )
    rerender(<DigitRoll value={36052} format={fmt} />)

    expect(rolls()).toHaveLength(1)
    // The one cell in motion holds the digit it left and the digit it is
    // rolling to; every other cell is untouched.
    expect(rolls()[0].element.textContent).toBe("12")
    finishAll()
    expect(container.textContent).toBe("36,052")
  })

  it("keeps the untouched digits still while 999 grows into 1,000", () => {
    const { container, rerender } = render(
      <DigitRoll value={999} format={fmt} />,
    )
    rerender(<DigitRoll value={1000} format={fmt} />)

    // The three nines roll to zeroes; the comma and the leading 1 are new
    // cells that fade in rather than roll.
    expect(rolls()).toHaveLength(3)
    expect(rolls().map((a) => a.element.textContent)).toEqual([
      "90",
      "90",
      "90",
    ])
    expect(entrances()).toHaveLength(2)
    expect(
      entrances().every((a) =>
        a.keyframes.every((frame) => frame.transform !== "translateY(-50%)"),
      ),
    ).toBe(true)
    finishAll()
    expect(container.textContent).toBe("1,000")
  })

  it("never rolls the thousands separator", () => {
    const { rerender } = render(<DigitRoll value={1234} format={fmt} />)
    rerender(<DigitRoll value={2234} format={fmt} />)

    expect(rolls()).toHaveLength(1)
    expect(rolls()[0].element.textContent).toBe("12")
    expect(
      animations.some((a) => (a.element.textContent ?? "").includes(",")),
    ).toBe(false)
  })

  it("rolls downwards when the value falls", () => {
    const { rerender } = render(<DigitRoll value={5} format={fmt} />)
    rerender(<DigitRoll value={4} format={fmt} />)

    expect(rolls()).toHaveLength(1)
    expect(rolls()[0].keyframes.map((frame) => frame.transform)).toEqual([
      "translateY(-50%)",
      "translateY(0)",
    ])
    // Rolling down puts the new digit above the old one.
    expect(rolls()[0].element.textContent).toBe("45")
  })

  it("coalesces updates inside the window instead of interrupting the roll", () => {
    const { container, rerender } = render(
      <DigitRoll value={100} format={fmt} />,
    )
    rerender(<DigitRoll value={200} format={fmt} />)
    expect(rolls()).toHaveLength(1)

    // Two more updates land while the window is open. Neither starts an
    // animation, and neither touches the one already running.
    act(() => {
      vi.advanceTimersByTime(100)
    })
    rerender(<DigitRoll value={300} format={fmt} />)
    act(() => {
      vi.advanceTimersByTime(100)
    })
    rerender(<DigitRoll value={400} format={fmt} />)
    expect(rolls()).toHaveLength(1)
    expect(rolls()[0].cancelled).toBe(false)

    finishAll()
    expect(container.textContent).toBe("200")

    // When the window closes, one roll goes straight to the newest value.
    // 300 was dropped, never painted: the cell rolls 2 -> 4.
    act(() => {
      vi.advanceTimersByTime(2_000)
    })
    expect(rolls()).toHaveLength(2)
    expect(rolls()[1].element.textContent).toBe("24")
    finishAll()
    expect(container.textContent).toBe("400")
  })

  it("holds one deferred roll rather than queueing one per update", () => {
    const { container, rerender } = render(<DigitRoll value={1} format={fmt} />)
    rerender(<DigitRoll value={2} format={fmt} />)
    for (const value of [3, 4, 5, 6]) {
      act(() => {
        vi.advanceTimersByTime(200)
      })
      rerender(<DigitRoll value={value} format={fmt} />)
    }
    act(() => {
      vi.advanceTimersByTime(5_000)
    })

    expect(rolls()).toHaveLength(2)
    finishAll()
    expect(container.textContent).toBe("6")
  })
})
