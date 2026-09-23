import { beforeEach, describe, expect, it, vi } from "vitest"

import { useWindow } from "@/hooks/use-window"

const visit = vi.fn()

vi.mock("@inertiajs/react", () => ({
  router: {
    visit: (...args: unknown[]) => {
      visit(...args)
    },
  },
  usePage: () => ({ props: { window: "1h" }, url: "" }),
}))

describe("useWindow", () => {
  beforeEach(() => {
    visit.mockReset()
    globalThis.history.replaceState(
      {},
      "",
      "/apps/1/envs/10/requests?window=1h&step=1m",
    )
  })

  it("drops a chosen step when the window changes, so the new window draws at its own default", () => {
    useWindow().set("7d")
    const url = new URL(String(visit.mock.calls[0][0]))
    expect(url.searchParams.get("window")).toBe("7d")
    expect(url.searchParams.has("step")).toBe(false)
  })

  it("drops the step for a custom range too", () => {
    useWindow().setRange("2026-09-01T00:00:00Z", "2026-09-02T00:00:00Z")
    const url = new URL(String(visit.mock.calls[0][0]))
    expect(url.searchParams.has("step")).toBe(false)
    expect(url.searchParams.has("window")).toBe(false)
  })
})
