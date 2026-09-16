import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { UtilisationBar } from "@/components/railwatch/utilisation-bar"

const fill = () => screen.getByRole("meter").firstElementChild

describe("UtilisationBar", () => {
  it("stays green while the pool has room", () => {
    render(<UtilisationBar busy={3} max={10} />)
    expect(screen.getByText("3/10")).toBeInTheDocument()
    expect(fill()).toHaveClass("bg-live")
    expect(fill()).toHaveStyle({ width: "30%" })
  })

  it("turns amber from 70% busy", () => {
    render(<UtilisationBar busy={7} max={10} />)
    expect(fill()).toHaveClass("bg-warning")
  })

  it("turns red from 90% busy", () => {
    render(<UtilisationBar busy={9} max={10} />)
    expect(fill()).toHaveClass("bg-danger")
  })

  it("never draws past full when more threads are busy than the pool reports", () => {
    render(<UtilisationBar busy={12} max={10} />)
    expect(fill()).toHaveStyle({ width: "100%" })
  })

  it("renders a dash instead of dividing by an unknown pool size", () => {
    render(<UtilisationBar busy={3} max={null} />)
    expect(screen.queryByRole("meter")).not.toBeInTheDocument()
    expect(screen.getByText("–")).toBeInTheDocument()
  })
})
