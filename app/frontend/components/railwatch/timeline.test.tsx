import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { Timeline } from "@/components/railwatch/timeline"
import type { TimelineEntry } from "@/types"

function tickTexts(container: HTMLElement): string[] {
  return [...container.querySelectorAll(".h-4.select-none > span")].map(
    (el) => el.textContent ?? "",
  )
}

describe("Timeline axis ticks", () => {
  it("picks a 10ms interval for an 80ms span", () => {
    const { container } = render(
      <Timeline entries={[]} total={80} stages={{}} />,
    )
    expect(tickTexts(container)).toEqual([
      "0ms",
      "10ms",
      "20ms",
      "30ms",
      "40ms",
      "50ms",
      "60ms",
      "70ms",
      "80ms",
    ])
  })

  it("picks a 50ms interval for a 400ms span", () => {
    const { container } = render(
      <Timeline entries={[]} total={400} stages={{}} />,
    )
    expect(tickTexts(container)).toEqual([
      "0ms",
      "50ms",
      "100ms",
      "150ms",
      "200ms",
      "250ms",
      "300ms",
      "350ms",
      "400ms",
    ])
  })

  it("picks a 500ms interval for a 3s span, crossing into second-scale labels", () => {
    const { container } = render(
      <Timeline entries={[]} total={3000} stages={{}} />,
    )
    expect(tickTexts(container)).toEqual([
      "0ms",
      "500ms",
      "1.00s",
      "1.50s",
      "2.00s",
      "2.50s",
      "3.00s",
    ])
  })
})

const twoEntries: TimelineEntry[] = [
  {
    type: "cache_event",
    id: 1,
    offset: 0,
    duration: 20,
    label: "cache read",
    stage: null,
  },
  {
    type: "outgoing_request",
    id: 2,
    offset: 20,
    duration: 5,
    label: "outgoing thing",
    stage: null,
  },
]

describe("Timeline entry rows", () => {
  it("renders one row per entry", () => {
    const { container } = render(
      <Timeline entries={twoEntries} total={100} stages={{}} />,
    )
    expect(
      container.querySelectorAll('div[style*="content-visibility"]'),
    ).toHaveLength(2)
    expect(screen.getByText("cache read")).toBeInTheDocument()
    expect(screen.getByText("outgoing thing")).toBeInTheDocument()
  })

  it("hides only the toggled type's rows when its chip is clicked", async () => {
    const user = userEvent.setup()
    const { container } = render(
      <Timeline entries={twoEntries} total={100} stages={{}} />,
    )

    // Both a legend chip and a row label render the text "Cache"; the chip
    // is the one inside the rounded-full toggle button.
    const cacheChip = [
      ...container.querySelectorAll("button.rounded-full"),
    ].find((button) => button.textContent?.includes("Cache"))
    await user.click(cacheChip!)

    expect(screen.queryByText("cache read")).not.toBeInTheDocument()
    expect(screen.getByText("outgoing thing")).toBeInTheDocument()
  })

  it("marks an entry spanning over 10% of the total as slow", () => {
    const { container } = render(
      <Timeline entries={twoEntries} total={100} stages={{}} />,
    )
    // cache_event: 20/100 = 20%, over the 10% threshold. Scope to the bar
    // div, since the legend chip's dot also carries the bg-violet-500 class.
    const slowBar = container.querySelector("div.bg-violet-500")
    expect(slowBar).toHaveClass("ring-foreground/30")

    // outgoing_request: 5/100 = 5%, under the threshold.
    const fastBar = container.querySelector("div.bg-orange-500")
    expect(fastBar).not.toHaveClass("ring-foreground/30")
    expect(fastBar).toHaveClass("opacity-70")
  })

  it("renders a diamond marker instead of a bar for an exception entry", () => {
    const entries: TimelineEntry[] = [
      {
        type: "exception",
        id: 3,
        offset: 10,
        duration: null,
        label: "Boom",
        stage: null,
      },
    ]
    const { container } = render(
      <Timeline entries={entries} total={100} stages={{}} />,
    )
    expect(container.querySelector(".rotate-45.bg-red-500")).toBeInTheDocument()
  })
})
