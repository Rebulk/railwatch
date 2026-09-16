import { fireEvent, render, screen } from "@testing-library/react"
import type { ReactNode } from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"

import Issues from "@/pages/issues/index"
import * as R from "@/routes"
import type { IssueRow } from "@/types"

const router = vi.hoisted(() => ({
  patch: vi.fn(),
  visit: vi.fn(),
  post: vi.fn(),
}))
vi.mock("@inertiajs/react", () => ({
  router,
  Head: () => null,
  usePage: () => ({ props: { applications: [] } }),
  Link: ({ href, children }: { href: string; children: ReactNode }) => (
    <a href={href}>{children}</a>
  ),
}))
vi.mock("@/layouts/app-layout", () => ({
  default: ({ children }: { children: ReactNode }) => <>{children}</>,
}))

const issue: IssueRow = {
  id: 7,
  key: "APP-7",
  title: "Failure",
  kind: "exception",
  status: "open",
  priority: "normal",
  occurrences: 1,
  affected_users: 1,
  last_seen_at: "2026-09-05T12:00:00Z",
}

beforeEach(() => vi.clearAllMocks())

function highlightIssue() {
  render(<Issues issues={[issue]} filters={{}} counts={{}} members={[]} />)
  fireEvent.keyDown(document.body, { key: "j" })
  expect(screen.getByText("APP-7").closest("tr")).toHaveAttribute(
    "data-state",
    "highlighted",
  )
}

describe("issue action shortcuts", () => {
  it.each([
    ["r", "resolve"],
    ["i", "ignore"],
    ["a", "assign_me"],
  ])("runs unmodified %s on the highlighted issue", (key, action) => {
    highlightIssue()
    fireEvent.keyDown(document.body, { key })
    expect(router.patch).toHaveBeenCalledExactlyOnceWith(
      R.issuePath(7),
      { action_name: action },
      { preserveScroll: true },
    )
  })

  it("does not mutate issues for browser shortcuts or IME input", () => {
    highlightIssue()
    for (const key of ["r", "i", "a"]) {
      for (const modifier of [
        { ctrlKey: true },
        { metaKey: true },
        { altKey: true },
        { shiftKey: true },
        { isComposing: true },
      ]) {
        fireEvent.keyDown(document.body, { key, ...modifier })
      }
    }
    expect(router.patch).not.toHaveBeenCalled()
  })

  it("yields issue actions to focused controls and handled events", () => {
    highlightIssue()
    fireEvent.keyDown(screen.getByPlaceholderText("Search or source:browser"), {
      key: "r",
    })
    fireEvent.keyDown(screen.getByRole("checkbox", { name: "Select APP-7" }), {
      key: "a",
    })
    fireEvent.keyDown(screen.getByRole("link", { name: "APP-7" }), { key: "i" })
    const handled = new KeyboardEvent("keydown", {
      key: "r",
      bubbles: true,
      cancelable: true,
    })
    handled.preventDefault()
    fireEvent(document.body, handled)
    expect(router.patch).not.toHaveBeenCalled()
  })
})
