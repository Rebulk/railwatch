import { fireEvent, render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import type { FilterField } from "@/components/railwatch/filter-bar"
import { FilterBar } from "@/components/railwatch/filter-bar"

const fields: FilterField[] = [
  { key: "status", label: "Status", options: ["success", "error"] },
  { key: "method", label: "Method" },
]

describe("FilterBar chips", () => {
  it("renders one chip per parsed key:value token", () => {
    render(
      <FilterBar
        value="status:500 method:GET"
        fields={fields}
        onChange={vi.fn()}
      />,
    )
    expect(screen.getByText("status:500")).toBeInTheDocument()
    expect(screen.getByText("method:GET")).toBeInTheDocument()
  })

  it("renders no chips for a value with only free text", () => {
    render(
      <FilterBar value="broken thing" fields={fields} onChange={vi.fn()} />,
    )
    expect(screen.queryByLabelText(/Remove .* filter/)).not.toBeInTheDocument()
  })
})

describe("FilterBar typing", () => {
  it("calls onChange with the typed query when Enter is pressed", async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(<FilterBar value="" fields={fields} onChange={onChange} />)

    const input = screen.getByPlaceholderText("Filter...")
    await user.type(input, "status:200{Enter}")

    expect(onChange).toHaveBeenCalledWith("status:200")
  })
})

describe("FilterBar chip removal", () => {
  it("removes only the clicked chip's token, keeping the other", async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(
      <FilterBar
        value="status:500 method:GET"
        fields={fields}
        onChange={onChange}
      />,
    )

    await user.click(screen.getByLabelText("Remove status filter"))

    expect(onChange).toHaveBeenCalledWith("method:GET")
  })
})

describe("FilterBar field autocomplete", () => {
  it("lists every provided field, with options for fields that have them", async () => {
    render(<FilterBar value="" fields={fields} onChange={vi.fn()} />)

    fireEvent.click(screen.getByRole("button", { name: "Add filter" }))

    expect(await screen.findByText("Status")).toBeInTheDocument()
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByText("error")).toBeInTheDocument()
    expect(screen.getByText("Method")).toBeInTheDocument()
    expect(screen.getByText("method:…")).toBeInTheDocument()
  })
})
