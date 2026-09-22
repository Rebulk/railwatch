import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { DiagnosticsPanel } from "./diagnostics-panel"
import type { QueryDiagnostics } from "./diagnostics-types"

const diagnostics: QueryDiagnostics = {
  status: "analyzed",
  adapter: "PostgreSQL",
  connection: "primary_replica",
  source: "app/models/event.rb:12",
  limitations: [
    "Index candidates may already exist; verify them on the source database.",
  ],
  recommendations: [
    {
      id: "candidate",
      kind: "index",
      basis: "sql",
      title: "Review a composite index on events",
      explanation: "An index using tenant_id, created_at may help.",
      action: "Compare existing indexes and validate a representative plan.",
      evidence: [{ source: "sql", text: "tenant_id = ?" }],
    },
    {
      id: "scan",
      kind: "scan",
      basis: "plan",
      title: "Scan in the captured plan",
      explanation: "The optimizer can choose this even when an index exists.",
      action: "Check filter selectivity and statistics.",
      evidence: [{ source: "plan", text: "Seq Scan on events", line: 3 }],
    },
  ],
}

describe("DiagnosticsPanel", () => {
  it("distinguishes SQL heuristics from stored plan facts and exposes their evidence", () => {
    render(<DiagnosticsPanel diagnostics={diagnostics} />)
    expect(screen.getByText("primary_replica")).toBeInTheDocument()
    expect(screen.getByText("PostgreSQL")).toBeInTheDocument()
    expect(screen.getByText("app/models/event.rb:12")).toBeInTheDocument()
    const candidate = screen
      .getByRole("heading", { name: "Review a composite index on events" })
      .closest("article")!
    expect(within(candidate).getByText("SQL heuristic")).toBeInTheDocument()
    expect(within(candidate).getByText("tenant_id = ?")).toBeInTheDocument()
    const plan = screen
      .getByRole("heading", { name: "Scan in the captured plan" })
      .closest("article")!
    expect(within(plan).getByText("Captured plan")).toBeInTheDocument()
    expect(within(plan).getByText("Stored plan · line 3")).toBeInTheDocument()
    expect(screen.getByText(/may already exist/)).toBeInTheDocument()
  })

  it("does not imply an unsupported query is healthy", () => {
    render(
      <DiagnosticsPanel
        diagnostics={{
          ...diagnostics,
          status: "unsupported",
          recommendations: [],
        }}
      />,
    )
    expect(
      screen.getByText(/insufficient for specific SQL advice/),
    ).toBeInTheDocument()
  })

  it("qualifies an analyzed query without findings", () => {
    render(
      <DiagnosticsPanel
        diagnostics={{ ...diagnostics, recommendations: [] }}
      />,
    )
    expect(
      screen.getByText(/does not establish that the query is optimal/),
    ).toBeInTheDocument()
  })

  it("renders captured SQL as text and marks shortened evidence", () => {
    const recommendation = {
      ...diagnostics.recommendations[0],
      evidence: [
        {
          source: "sql" as const,
          text: "<script>alert(1)</script>",
          truncated: true,
        },
      ],
    }
    const { container } = render(
      <DiagnosticsPanel
        diagnostics={{ ...diagnostics, recommendations: [recommendation] }}
      />,
    )
    expect(screen.getByText("<script>alert(1)</script>")).toBeInTheDocument()
    expect(screen.getByText(/excerpt truncated/)).toBeInTheDocument()
    expect(container.querySelector("script")).toBeNull()
  })
})
