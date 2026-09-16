import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"

import { DataTable } from "@/components/railwatch/data-table"

interface Row {
  id: number
  name: string
}

const rows: Row[] = [
  { id: 1, name: "Alpha" },
  { id: 2, name: "Bravo" },
]

const columns = [{ key: "name", header: "Name", cell: (r: Row) => r.name }]

function fireKey(key: string) {
  fireEvent.keyDown(document, { key })
}

describe("DataTable keyboard highlight", () => {
  it("moves keyboard ownership when the second table receives focus", () => {
    const firstOpen = vi.fn()
    const secondOpen = vi.fn()
    render(
      <>
        <DataTable
          rows={rows}
          columns={columns}
          rowKey={(r) => r.id}
          keyboardNav={{ onOpen: firstOpen }}
        />
        <DataTable
          rows={[{ id: 3, name: "Charlie" }]}
          columns={columns}
          rowKey={(r) => r.id}
          keyboardNav={{ onOpen: secondOpen }}
        />
      </>,
    )
    fireKey("j")
    const secondRow = screen.getByText("Charlie").closest("tr")!
    fireEvent.focus(secondRow)
    fireKey("j")
    fireKey("Enter")
    expect(firstOpen).not.toHaveBeenCalled()
    expect(secondOpen).toHaveBeenCalledExactlyOnceWith({
      id: 3,
      name: "Charlie",
    })
    expect(screen.getByText("Alpha").closest("tr")).not.toHaveAttribute(
      "data-state",
      "highlighted",
    )
  })
  it("highlights a row after j and clears the highlight on Escape", () => {
    render(
      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => r.id}
        keyboardNav={{ onOpen: vi.fn() }}
      />,
    )
    const row = screen.getByText("Alpha").closest("tr")!
    expect(row).not.toHaveAttribute("data-state", "highlighted")

    fireKey("j")
    expect(row).toHaveAttribute("data-state", "highlighted")
    expect(row).toHaveClass("bg-accent")

    fireKey("Escape")
    expect(row).not.toHaveAttribute("data-state", "highlighted")
  })

  it("does not highlight rows when keyboardNav is not provided", () => {
    render(<DataTable rows={rows} columns={columns} rowKey={(r) => r.id} />)
    fireKey("j")
    const row = screen.getByText("Alpha").closest("tr")!
    expect(row).not.toHaveAttribute("data-state", "highlighted")
  })

  it("calls onOpen with the highlighted row on Enter", () => {
    const onOpen = vi.fn()
    render(
      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => r.id}
        keyboardNav={{ onOpen }}
      />,
    )
    fireKey("j")
    fireKey("Enter")
    expect(onOpen).toHaveBeenCalledExactlyOnceWith(rows[0])
  })
})
