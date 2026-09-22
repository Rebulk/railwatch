import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { type Attention, NeedsAttention } from "./needs-attention"

const attention: Attention = {
  open_issue_count: 15,
  recent_issue_count: 9,
  health_count: 1,
  health_status: "warning",
  checked_at: "2026-09-22T12:00:00Z",
  from: "2026-09-21T12:00:00Z",
  to: "2026-09-22T12:00:00Z",
  items: [
    {
      id: "health:capture",
      type: "health",
      severity: "warning",
      title: "Capture loss recorded",
      detail: "Three client drops in inspected batches.",
    },
    {
      id: "issue:42",
      type: "issue",
      issue_id: 42,
      key: "APP-42",
      title: "Slow checkout",
      priority: "high",
      kind: "performance",
      regressed: true,
      occurrences: 19,
      affected_users: 0,
      last_seen_at: "2026-09-22T11:55:00Z",
      deploy: "abc123",
      evidence: {
        metric: "p95",
        unit: "milliseconds",
        value: 900,
        limit: 500,
        baseline_mean: 300,
        from: "2026-09-22T11:50:00Z",
        to: "2026-09-22T11:55:00Z",
      },
    },
  ],
}

describe("NeedsAttention", () => {
  it("links health and issue evidence and labels scope and counts accurately", () => {
    render(
      <NeedsAttention
        attention={attention}
        applicationId={2}
        environmentId={3}
      />,
    )
    expect(
      screen.getByRole("link", { name: "Capture loss recorded" }),
    ).toHaveAttribute("href", "/apps/2/envs/3/monitoring_health")
    expect(
      screen.getByRole("link", { name: "APP-42 · Slow checkout" }),
    ).toHaveAttribute("href", "/issues/42")
    expect(
      screen.getByText(/p95 900 ms · threshold 500 ms · baseline mean 300 ms/),
    ).toBeInTheDocument()
    expect(
      screen.getByText(
        /19 breached evaluation windows over the issue’s lifetime/,
      ),
    ).toBeInTheDocument()
    expect(screen.getByText("Regressed in this window")).toBeInTheDocument()
    expect(screen.getByText(/1 of 9 open issues last seen/)).toBeInTheDocument()
    expect(screen.getByText(/recorded release/)).toBeInTheDocument()
  })

  it("keeps missing health evidence visible even when there are no issues", () => {
    render(
      <NeedsAttention
        applicationId={2}
        environmentId={3}
        attention={{
          ...attention,
          open_issue_count: 0,
          recent_issue_count: 0,
          health_status: "unknown",
          items: [
            {
              id: "health:unknown",
              type: "health",
              severity: "unknown",
              title: "Monitoring evidence is incomplete",
              detail: "No batches have arrived.",
            },
          ],
        }}
      />,
    )
    expect(screen.getByText("Evidence unavailable")).toBeInTheDocument()
    expect(screen.getByText("No batches have arrived.")).toBeInTheDocument()
    expect(
      screen.queryByText("No recorded findings in this window"),
    ).not.toBeInTheDocument()
  })

  it("qualifies an empty result instead of asserting complete coverage", () => {
    render(
      <NeedsAttention
        applicationId={2}
        environmentId={3}
        attention={{
          ...attention,
          items: [],
          recent_issue_count: 0,
          health_count: 0,
          health_status: "ok",
        }}
      />,
    )
    expect(
      screen.getByText("No recorded findings in this window"),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/Sampling and configured detectors limit coverage/),
    ).toBeInTheDocument()
  })
})
