import { act, fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

import { StepPicker } from "@/components/railwatch/step-picker"

const visit = vi.fn()
let pageProps: Record<string, unknown> = {}

vi.mock("@inertiajs/react", () => ({
  router: {
    visit: (...args: unknown[]) => {
      visit(...args)
    },
  },
  usePage: () => ({ props: pageProps, url: "" }),
}))

// Radix opens its menu on a primary-button pointerdown; see
// saved-views.test.tsx for why a plain MouseEvent is what jsdom can send.
const openMenu = (trigger: HTMLElement) =>
  act(() => {
    trigger.dispatchEvent(
      new MouseEvent("pointerdown", { bubbles: true, button: 0 }),
    )
  })

describe("StepPicker", () => {
  beforeEach(() => {
    visit.mockReset()
    globalThis.history.replaceState(
      {},
      "",
      "/apps/1/envs/10/requests?window=1h&q=status%3A5xx",
    )
  })

  it("offers only the widths the server says fit the window", () => {
    pageProps = { step: "1m", steps: ["1m", "5m", "15m"] }
    render(<StepPicker />)

    openMenu(screen.getByLabelText("Chart buckets: 1 minute"))

    expect(screen.getByText("5 minutes")).toBeInTheDocument()
    expect(screen.queryByText("1 hour")).not.toBeInTheDocument()
  })

  it("sets ?step= on the current URL, keeping the window and filters", () => {
    pageProps = { step: "1m", steps: ["1m", "5m", "15m"] }
    render(<StepPicker />)

    openMenu(screen.getByLabelText("Chart buckets: 1 minute"))
    fireEvent.click(screen.getByText("5 minutes"))

    const url = new URL(String(visit.mock.calls[0][0]))
    expect(url.searchParams.get("step")).toBe("5m")
    expect(url.searchParams.get("window")).toBe("1h")
    expect(url.searchParams.get("q")).toBe("status:5xx")
  })

  it("renders nothing when the window offers a single width", () => {
    pageProps = { step: "1d", steps: ["1d"] }
    const { container } = render(<StepPicker />)
    expect(container).toBeEmptyDOMElement()
  })
})
