import { render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { LiveDot } from "@/components/railwatch/live-dot"
import { RelativeTime } from "@/components/railwatch/relative-time"

const now = new Date("2026-09-03T12:00:00.000Z")

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(now)
})

afterEach(() => {
  vi.useRealTimers()
})

describe("RelativeTime", () => {
  it('renders "never" when iso is null', () => {
    render(<RelativeTime iso={null} />)
    expect(screen.getByText("never")).toBeInTheDocument()
  })

  it('renders "never" when iso is undefined', () => {
    render(<RelativeTime iso={undefined} />)
    expect(screen.getByText("never")).toBeInTheDocument()
  })

  it("renders elapsed minutes for a timestamp 5 minutes in the past", () => {
    render(<RelativeTime iso="2026-09-03T11:55:00.000Z" />)
    expect(screen.getByText("5m ago")).toBeInTheDocument()
  })

  it("sets the title to the formatted absolute time", () => {
    render(<RelativeTime iso="2026-09-03T11:55:00.000Z" />)
    expect(screen.getByText("5m ago")).toHaveAttribute(
      "title",
      expect.stringContaining("11:55"),
    )
  })
})

describe("LiveDot", () => {
  it("leaves all three lamps unlit with no ping when lastSeenAt is null", () => {
    const { container } = render(<LiveDot lastSeenAt={null} />)
    expect(container.querySelectorAll(".bg-neutral-400\\/15")).toHaveLength(3)
    expect(container.querySelector(".bg-live")).not.toBeInTheDocument()
    expect(container.querySelector(".bg-warning")).not.toBeInTheDocument()
    expect(container.querySelector(".animate-ping")).not.toBeInTheDocument()
  })

  it("renders live green with a ping when last seen within the freshness threshold", () => {
    const { container } = render(
      <LiveDot lastSeenAt="2026-09-03T11:59:30.000Z" thresholdMs={60_000} />,
    )
    expect(container.querySelector(".bg-live")).toBeInTheDocument()
    expect(container.querySelector(".animate-ping")).toBeInTheDocument()
  })

  it("lights the top lamp red when erroring, even with fresh telemetry", () => {
    const { container } = render(
      <LiveDot
        lastSeenAt="2026-09-03T11:59:30.000Z"
        thresholdMs={60_000}
        erroring
      />,
    )
    expect(container.querySelector(".bg-danger")).toBeInTheDocument()
    expect(container.querySelector(".bg-live")).not.toBeInTheDocument()
    expect(container.querySelector(".animate-ping")).toBeInTheDocument()
  })

  it("renders warning amber with no ping when last seen past the freshness threshold", () => {
    const { container } = render(
      <LiveDot lastSeenAt="2026-09-03T11:58:00.000Z" thresholdMs={60_000} />,
    )
    expect(container.querySelector(".bg-warning")).toBeInTheDocument()
    expect(container.querySelector(".animate-ping")).not.toBeInTheDocument()
  })
})
