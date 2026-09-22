import { render, screen } from "@testing-library/react"
import type { ReactNode } from "react"
import { describe, expect, it, vi } from "vitest"

import MonitoringHealth from "./show"

vi.mock("@/layouts/env-layout", () => ({
  default: ({ children }: { children: ReactNode }) => <>{children}</>,
}))
vi.mock("@/components/railwatch/page-header", () => ({
  PageHeader: ({
    title,
    description,
  }: {
    title: ReactNode
    description: ReactNode
  }) => (
    <header>
      <h1>{title}</h1>
      <p>{description}</p>
    </header>
  ),
}))

const snapshot: Parameters<typeof MonitoringHealth>[0]["monitoring_health"] = {
  checked_at: "2026-09-22T14:20:00Z",
  host: "cloud",
  status: "unknown",
  attention: [],
  freshness: { status: "unknown", ingest: { status: "unknown", at: null } },
  capture: {
    status: "unknown",
    accepted: null,
    rejected: null,
    dropped_by_client: null,
  },
  storage: {
    status: "ok",
    adapter: "SQLite",
    data_bytes: 4096,
    wal_bytes: 0,
    physical_bytes: 4096,
  },
  retention: { status: "unknown" },
  followups: { status: "ok", pending: 0, oldest_at: null },
  maintenance: {
    status: "not_applicable",
    message: "Cloud uses its own maintenance job queue.",
  },
  writer: {
    status: "not_applicable",
    message: "No embedded writer in this environment.",
  },
  export: { status: "not_applicable", message: "Cloud receives telemetry." },
}

describe("Monitoring health", () => {
  it("shows measured zero bytes separately from unknown capture counts", () => {
    render(<MonitoringHealth monitoring_health={snapshot} />)

    expect(screen.getByText("WAL file").nextElementSibling).toHaveTextContent(
      "0 B",
    )
    expect(
      screen.getByText("Accepted records").nextElementSibling,
    ).toHaveTextContent("Unknown")
    expect(
      screen.getByText("Pending follow-ups").nextElementSibling,
    ).toHaveTextContent("0")
    expect(
      screen.getByText("No embedded writer in this environment."),
    ).toBeInTheDocument()
    expect(screen.queryByText("Last success")).not.toBeInTheDocument()
  })

  it("qualifies bounded batch totals and follow-up counts", () => {
    render(
      <MonitoringHealth
        monitoring_health={{
          ...snapshot,
          capture: {
            status: "warning",
            batches: 1000,
            limited: true,
            accepted: 50,
            rejected: 1,
            dropped_by_client: 2,
          },
          followups: { status: "warning", pending: 200, limited: true },
        }}
      />,
    )

    expect(
      screen.getByText(/Totals are lower bounds for the last hour/),
    ).toBeInTheDocument()
    expect(
      screen.getByText("Pending follow-ups").nextElementSibling,
    ).toHaveTextContent("At least 200")
  })

  it("keeps export record shedding distinct from terminal delivery counters", () => {
    render(
      <MonitoringHealth
        monitoring_health={{
          ...snapshot,
          export: {
            status: "warning",
            destination_state: "deferred",
            counters: { shed: 13, rejected: 2 },
          },
        }}
      />,
    )

    expect(
      screen.getByText("shed records (lifetime)").nextElementSibling,
    ).toHaveTextContent("13")
    expect(
      screen.getByText("rejected deliveries (lifetime)").nextElementSibling,
    ).toHaveTextContent("2")
  })
})
