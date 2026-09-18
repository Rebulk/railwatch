import { describe, expect, it } from "vitest"

import { tenantPath } from "@/pages/tenants/tenant-path"

describe("tenantPath", () => {
  it("percent-encodes dots so Rails does not read them as a format separator", () => {
    expect(tenantPath(1, 2, "acme.co")).toBe("/apps/1/envs/2/tenants/acme%2Eco")
  })

  it("keeps the query string after the encoded segment", () => {
    expect(tenantPath(1, 2, "acme.co", { window: "7d" })).toBe(
      "/apps/1/envs/2/tenants/acme%2Eco?window=7d",
    )
  })

  it("leaves a tenant without a dot exactly as js-routes escaped it", () => {
    expect(tenantPath(1, 2, "acme co/uk")).toBe(
      "/apps/1/envs/2/tenants/acme%20co%2Fuk",
    )
  })
})
