import { describe, expect, it } from "vitest"

import { executionPath } from "@/lib/execution-path"

const path = (source: string | null, executionId: string | null = "exec-1") =>
  executionPath({
    applicationId: 12,
    environmentId: 34,
    source,
    executionId,
  })

describe("executionPath", () => {
  it("routes request parents", () => {
    expect(path("request")).toBe("/apps/12/envs/34/requests/exec-1")
  })

  it.each(["job", "job_attempt"])("routes %s parents to jobs", (source) => {
    expect(path(source)).toBe("/apps/12/envs/34/jobs/exec-1")
  })

  it("routes scheduled task parents", () => {
    expect(path("scheduled_task")).toBe(
      "/apps/12/envs/34/scheduled_tasks/exec-1",
    )
  })

  it("routes command parents", () => {
    expect(path("command")).toBe("/apps/12/envs/34/commands/exec-1")
  })

  it.each(["channel_action", "action_cable", null, "future_parent"])(
    "falls back to the generic execution detail for %s",
    (source) => {
      expect(path(source)).toBe("/apps/12/envs/34/executions/exec-1")
    },
  )

  it("does not create a server link for browser-only events", () => {
    expect(path("browser")).toBeNull()
  })

  it("does not create a link without an execution id", () => {
    expect(path("request", null)).toBeNull()
  })
})
