// @vitest-environment node
import { describe, expect, it } from "vitest"

// The Inertia SSR server imports the same entrypoint the browser runs, with
// no window and no document. Railwatch must neither crash it on import nor
// when the entrypoint calls startRailwatch() at its top level, which is the
// line the install generator writes.
describe("under server-side rendering", () => {
  it("imports, and startRailwatch() does nothing, with no DOM", async () => {
    expect(typeof window).toBe("undefined")
    expect(typeof document).toBe("undefined")

    const railwatch = await import("@/lib/railwatch")

    expect(() => railwatch.startRailwatch()).not.toThrow()
    expect(() => railwatch.railwatchRootOptions()).not.toThrow()
  })
})
