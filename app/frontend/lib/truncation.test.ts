import { describe, expect, it } from "vitest"

import { truncationNotice } from "@/lib/truncation"

describe("truncationNotice", () => {
  it("states what was recorded, what was dropped, and why", () => {
    expect(truncationNotice(2478, 3324, 26_214_400)).toBe(
      "2,478 of 5,802 child records recorded; 3,324 dropped (25.0 MB) because this execution's tree outgrew execution_buffer_bytes. The timeline below is the first 42.7% of it.",
    )
  })

  it("omits the byte figure when an older gem did not send one", () => {
    expect(truncationNotice(10, 5, null)).toBe(
      "10 of 15 child records recorded; 5 dropped because this execution's tree outgrew execution_buffer_bytes. The timeline below is the first 66.7% of it.",
    )
  })
})
