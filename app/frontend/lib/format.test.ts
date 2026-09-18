import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { ago, bytes, count, ms, pct, statusTone } from "@/lib/format"

describe("ms", () => {
  it("renders a dash for null", () => {
    expect(ms(null)).toBe("–")
  })

  it("renders a dash for undefined", () => {
    expect(ms(undefined)).toBe("–")
  })

  it("renders sub-millisecond durations in microseconds", () => {
    expect(ms(0.5)).toBe("500µs")
  })

  it("renders zero in milliseconds, not microseconds", () => {
    expect(ms(0)).toBe("0.0ms")
  })

  it("renders sub-second durations in milliseconds with the given precision", () => {
    expect(ms(42.567, 1)).toBe("42.6ms")
  })

  it("renders exactly 1ms in milliseconds", () => {
    expect(ms(1)).toBe("1.0ms")
  })

  it("renders durations at the 1000ms threshold in seconds", () => {
    expect(ms(1000)).toBe("1.00s")
  })

  it("renders durations above the 1000ms threshold in seconds", () => {
    expect(ms(1500)).toBe("1.50s")
  })

  it("renders durations just under the 1000ms threshold in milliseconds", () => {
    expect(ms(999.9)).toBe("999.9ms")
  })
})

describe("count", () => {
  it("renders a dash for null", () => {
    expect(count(null)).toBe("–")
  })

  it("renders a dash for undefined", () => {
    expect(count(undefined)).toBe("–")
  })

  it("renders small counts with locale grouping, not an abbreviation", () => {
    expect(count(9999)).toBe("9,999")
  })

  it("abbreviates counts at the 10k threshold with k", () => {
    expect(count(10_000)).toBe("10.0k")
  })

  it("abbreviates counts above the 10k threshold with k", () => {
    expect(count(12_345)).toBe("12.3k")
  })

  it("renders counts just under the 1M threshold with k", () => {
    expect(count(999_999)).toBe("1000.0k")
  })

  it("abbreviates counts at the 1M threshold with M", () => {
    expect(count(1_000_000)).toBe("1.0M")
  })

  it("abbreviates counts above the 1M threshold with M", () => {
    expect(count(2_500_000)).toBe("2.5M")
  })
})

describe("bytes", () => {
  it("renders a dash for null", () => {
    expect(bytes(null)).toBe("–")
  })

  it("renders a dash for undefined", () => {
    expect(bytes(undefined)).toBe("–")
  })

  it("renders a dash for zero, since 0 is falsy", () => {
    expect(bytes(0)).toBe("–")
  })

  it("renders small byte counts as-is", () => {
    expect(bytes(512)).toBe("512 B")
  })

  it("abbreviates at the 1KB threshold with KB", () => {
    expect(bytes(1024)).toBe("1.0 KB")
  })

  it("abbreviates above the 1KB threshold with KB", () => {
    expect(bytes(1536)).toBe("1.5 KB")
  })

  it("abbreviates at the 1MB threshold with MB", () => {
    expect(bytes(1024 * 1024)).toBe("1.0 MB")
  })

  it("abbreviates at the 1GB threshold with GB", () => {
    expect(bytes(1024 * 1024 * 1024)).toBe("1.0 GB")
  })
})

describe("pct", () => {
  it("renders 0% when the denominator is zero, avoiding a divide-by-zero NaN", () => {
    expect(pct(5, 0)).toBe("0%")
  })

  it("renders a percentage to one decimal place", () => {
    expect(pct(1, 4)).toBe("25.0%")
  })

  it("renders a non-terminating percentage rounded to one decimal place", () => {
    expect(pct(1, 3)).toBe("33.3%")
  })
})

describe("ago", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-09-03T12:00:00.000Z"))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("renders 'never' for a null timestamp", () => {
    expect(ago(null)).toBe("never")
  })

  it("renders 'never' for an undefined timestamp", () => {
    expect(ago(undefined)).toBe("never")
  })

  it("renders seconds just under the 60s boundary in seconds", () => {
    expect(ago("2026-09-03T11:59:01.000Z")).toBe("59s ago")
  })

  it("renders exactly 60s ago in minutes, not seconds", () => {
    expect(ago("2026-09-03T11:59:00.000Z")).toBe("1m ago")
  })

  it("renders minutes just under the 60m boundary in minutes", () => {
    expect(ago("2026-09-03T11:01:00.000Z")).toBe("59m ago")
  })

  it("renders exactly 60m ago in hours, not minutes", () => {
    expect(ago("2026-09-03T11:00:00.000Z")).toBe("1h ago")
  })

  it("renders hours just under the 24h boundary in hours", () => {
    expect(ago("2026-09-02T13:00:00.000Z")).toBe("23h ago")
  })

  it("renders exactly 24h ago in days, not hours", () => {
    expect(ago("2026-09-02T12:00:00.000Z")).toBe("1d ago")
  })

  it("renders multiple days ago in days", () => {
    expect(ago("2026-08-30T12:00:00.000Z")).toBe("4d ago")
  })
})

describe("statusTone", () => {
  it("returns destructive for a failed outcome regardless of status", () => {
    expect(statusTone(200, "failed")).toBe("destructive")
  })

  it("returns success for a processed outcome regardless of status", () => {
    expect(statusTone(500, "processed")).toBe("success")
  })

  it("returns muted when there is no status and no outcome", () => {
    expect(statusTone(null)).toBe("muted")
  })

  it("returns destructive for 5xx statuses", () => {
    expect(statusTone(500)).toBe("destructive")
  })

  it("returns warning for 4xx statuses", () => {
    expect(statusTone(404)).toBe("warning")
  })

  it("returns muted for 3xx statuses", () => {
    expect(statusTone(301)).toBe("muted")
  })

  it("returns success for 2xx statuses", () => {
    expect(statusTone(200)).toBe("success")
  })
})
