import { afterEach, describe, expect, it } from "vitest"

import { applyMount, mountPath } from "@/lib/mount"
import {
  applicationEnvironmentOverviewPath,
  configure,
  issuePath,
} from "@/routes"

function withMount(content: string | null) {
  document.head.innerHTML =
    content === null ? "" : `<meta name="railwatch-mount" content="${content}">`
}

afterEach(() => {
  document.head.innerHTML = ""
  configure({ default_url_options: {} })
})

describe("mountPath", () => {
  it("is empty without the tag, as on the hosted platform", () => {
    withMount(null)
    expect(mountPath()).toBe("")
  })

  it("reads the mount point and drops a trailing slash", () => {
    withMount("/admin/railwatch/")
    expect(mountPath()).toBe("/admin/railwatch")
  })

  it("is empty for a root mount", () => {
    withMount("")
    expect(mountPath()).toBe("")
  })

  it("refuses anything that would point links at another origin", () => {
    for (const bad of [
      "//evil.example",
      "/\\evil.example",
      "https://evil.example",
      "railwatch",
    ]) {
      withMount(bad)
      expect(mountPath(), bad).toBe("")
    }
  })
})

describe("applyMount", () => {
  it("prefixes every route helper with the mount point", () => {
    withMount("/railwatch")
    expect(applyMount()).toBe("/railwatch")
    expect(applicationEnvironmentOverviewPath(1, 2)).toBe(
      "/railwatch/apps/1/envs/2",
    )
    expect(issuePath(7)).toBe("/railwatch/issues/7")
  })

  it("leaves the helpers at the root without a mount", () => {
    withMount(null)
    expect(applyMount()).toBe("")
    expect(issuePath(7)).toBe("/issues/7")
  })
})
