import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { Stat } from "@/components/railwatch/stat"

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
