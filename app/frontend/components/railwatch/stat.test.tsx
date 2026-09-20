import { render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { Stat } from "@/components/railwatch/stat"

// Whether live updates are flowing is the page's LiveToggle's business, and
// a Stat only reads it. Both it and the motion preference are steered from
// here so each gate can be opened and closed on its own.
let live = false
let reducedMotion = false

vi.mock("@/hooks/use-live", () => ({ useIsLive: () => live }))

let animations = 0

function fakeAnimate(): Animation {
  animations++
  return { cancel: () => undefined, onfinish: null } as unknown as Animation
}

beforeEach(() => {
  live = false
  reducedMotion = false
  animations = 0
  Element.prototype.animate = fakeAnimate
  window.matchMedia = ((query: string) => ({
    matches: query.includes("prefers-reduced-motion") && reducedMotion,
    media: query,
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
  })) as unknown as typeof window.matchMedia
})

afterEach(() => {
  delete (Element.prototype as Partial<Element>).animate
})

const thousands = (value: number) => value.toLocaleString("en-US")

describe("Stat delta", () => {
  it("shows an up arrow and live (green) colour when a goodDirection=up metric improves", () => {
    render(
      <Stat
        label="Success rate"
        value="99%"
        delta={{ current: 120, previous: 100, goodDirection: "up" }}
      />,
    )
    const delta = screen.getByText("20.0%")
    expect(delta.closest("span")).toHaveClass("text-live")
    expect(
      delta.closest("span")?.querySelector("svg.lucide-arrow-up"),
    ).toBeInTheDocument()
  })

  it("shows a down arrow and destructive colour when a goodDirection=up metric regresses", () => {
    render(
      <Stat
        label="Success rate"
        value="80%"
        delta={{ current: 80, previous: 100, goodDirection: "up" }}
      />,
    )
    const delta = screen.getByText("20.0%")
    expect(delta.closest("span")).toHaveClass("text-destructive")
    expect(
      delta.closest("span")?.querySelector("svg.lucide-arrow-down"),
    ).toBeInTheDocument()
  })

  it("shows a down arrow and live (green) colour when a goodDirection=down metric improves", () => {
    render(
      <Stat
        label="p99 latency"
        value="80ms"
        delta={{ current: 80, previous: 100, goodDirection: "down" }}
      />,
    )
    const delta = screen.getByText("20.0%")
    expect(delta.closest("span")).toHaveClass("text-live")
    expect(
      delta.closest("span")?.querySelector("svg.lucide-arrow-down"),
    ).toBeInTheDocument()
  })

  it("shows an up arrow and destructive colour when a goodDirection=down metric regresses", () => {
    render(
      <Stat
        label="p99 latency"
        value="120ms"
        delta={{ current: 120, previous: 100, goodDirection: "down" }}
      />,
    )
    const delta = screen.getByText("20.0%")
    expect(delta.closest("span")).toHaveClass("text-destructive")
    expect(
      delta.closest("span")?.querySelector("svg.lucide-arrow-up"),
    ).toBeInTheDocument()
  })

  it("hides the delta when the delta prop is not provided", () => {
    render(<Stat label="Requests" value="1,234" />)
    expect(screen.queryByText(/%$/)).not.toBeInTheDocument()
  })

  it("hides the delta when previous is 0", () => {
    render(
      <Stat
        label="Requests"
        value="1,234"
        delta={{ current: 100, previous: 0, goodDirection: "up" }}
      />,
    )
    expect(screen.queryByText(/%$/)).not.toBeInTheDocument()
  })
})

describe("Stat rolling value", () => {
  it("reads the number out in sr-only text and hides the animated digits from assistive tech", () => {
    live = true
    const { container } = render(
      <Stat label="Requests" roll={{ value: 36052, format: thousands }} />,
    )
    const decorative = container.querySelector("[aria-hidden='true']")
    const spoken = container.querySelector(".sr-only")
    expect(spoken).toHaveTextContent("36,052")
    expect(decorative).toBeInTheDocument()
    expect(decorative).toHaveTextContent("36,052")
    // A value changing every few seconds is not a live region, and a
    // generic wrapper may not carry an aria-label (ARIA 1.2 prohibits it).
    expect(container.querySelector("[aria-live]")).toBeNull()
    expect(container.querySelector("[aria-label]")).toBeNull()
  })

  it("does not animate on mount, even with live updates flowing", () => {
    live = true
    render(<Stat label="Requests" roll={{ value: 36052, format: thousands }} />)
    expect(animations).toBe(0)
  })

  it("swaps instantly with no animation while live updates are off", () => {
    const { container, rerender } = render(
      <Stat label="Requests" roll={{ value: 36052, format: thousands }} />,
    )
    rerender(
      <Stat label="Requests" roll={{ value: 36053, format: thousands }} />,
    )
    expect(animations).toBe(0)
    expect(container.querySelector(".sr-only")).toHaveTextContent("36,053")
    expect(container.querySelector("[aria-hidden='true']")).toHaveTextContent(
      "36,053",
    )
  })

  it("swaps instantly with no animation when the user prefers reduced motion", () => {
    live = true
    reducedMotion = true
    const { container, rerender } = render(
      <Stat label="Requests" roll={{ value: 36052, format: thousands }} />,
    )
    rerender(
      <Stat label="Requests" roll={{ value: 36053, format: thousands }} />,
    )
    expect(animations).toBe(0)
    expect(container.querySelector("[aria-hidden='true']")).toHaveTextContent(
      "36,053",
    )
    expect(container.querySelector(".sr-only")).toHaveTextContent("36,053")
  })

  it("animates the changed digit once live updates are flowing", () => {
    live = true
    const { rerender } = render(
      <Stat label="Requests" roll={{ value: 36052, format: thousands }} />,
    )
    rerender(
      <Stat label="Requests" roll={{ value: 36053, format: thousands }} />,
    )
    expect(animations).toBe(1)
  })

  it("stops animating and shows the plain number when live updates are turned off", () => {
    live = true
    const { container, rerender } = render(
      <Stat label="Requests" roll={{ value: 36052, format: thousands }} />,
    )
    live = false
    rerender(
      <Stat label="Requests" roll={{ value: 36053, format: thousands }} />,
    )
    expect(animations).toBe(0)
    expect(container.querySelector("[aria-hidden='true']")).toHaveTextContent(
      "36,053",
    )
  })

  it("leaves a pre-formatted string value alone, with no rolling cells", () => {
    live = true
    const { container } = render(<Stat label="Requests" value="36,052" />)
    expect(container.querySelector(".sr-only")).toBeNull()
    expect(container.querySelector("[aria-hidden='true']")).toBeNull()
    expect(container).toHaveTextContent("36,052")
  })
})
