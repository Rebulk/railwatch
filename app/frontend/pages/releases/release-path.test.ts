import { describe, expect, it } from "vitest"

import { releasePath } from "@/pages/releases/release-path"

describe("releasePath", () => {
  it("percent-encodes dots so Rails does not read them as a format separator", () => {
    expect(releasePath(1, 2, "v1.2.3")).toBe(
      "/apps/1/envs/2/releases/v1%2E2%2E3",
    )
  })

  it("keeps the query string after the encoded segment", () => {
    expect(releasePath(1, 2, "v1.2.3", { window: "7d" })).toBe(
      "/apps/1/envs/2/releases/v1%2E2%2E3?window=7d",
    )
  })

  it("leaves a deploy without a dot exactly as js-routes escaped it", () => {
    expect(releasePath(1, 2, "a1b2c3d")).toBe("/apps/1/envs/2/releases/a1b2c3d")
  })
})
