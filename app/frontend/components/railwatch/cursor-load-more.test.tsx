import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

import { CursorLoadMore } from "@/components/railwatch/cursor-load-more"

const { visit } = vi.hoisted(() => ({ visit: vi.fn() }))

vi.mock("@inertiajs/react", () => ({ router: { visit } }))

describe("CursorLoadMore", () => {
  beforeEach(() => visit.mockReset())

  it("stays hidden on the last page", () => {
    render(
      <CursorLoadMore
        meta={{ limit: 50, next_cursor: null, has_more: false }}
        href={(cursor) => `/logs?cursor=${cursor}`}
        only={["logs", "pagination"]}
      />,
    )

    expect(screen.queryByRole("button")).not.toBeInTheDocument()
  })

  it("requests only mergeable rows and cursor metadata while preserving the page", () => {
    render(
      <CursorLoadMore
        meta={{ limit: 25, next_cursor: "signed", has_more: true }}
        href={(cursor) => `/logs?cursor=${cursor}`}
        only={["logs", "pagination"]}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "Load 25 more" }))

    expect(visit).toHaveBeenCalledWith(
      "/logs?cursor=signed",
      expect.objectContaining({
        only: ["logs", "pagination"],
        preserveState: true,
        preserveScroll: true,
      }),
    )
  })
})
