import { render } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { loneDot } from "@/components/railwatch/series-chart"

const data = [{ p95: null }, { p95: 12 }, { p95: null }, { p95: 8 }, { p95: 9 }]

function renderDot(index: number, points = data) {
  const Dot = loneDot(points, "p95", "red")
  const { container } = render(
    <svg>
      <Dot cx={1} cy={1} index={index} />
    </svg>,
  )
  return container.querySelector("circle")
}

describe("loneDot", () => {
  it("draws a dot for a point with quiet buckets on both sides", () => {
    expect(renderDot(1)).not.toBeNull()
  })

  it("draws nothing for a point the line already joins to a neighbour", () => {
    expect(renderDot(3)).toBeNull()
    expect(renderDot(4)).toBeNull()
  })

  it("survives an index past the series it was built over instead of throwing (LC-43)", () => {
    expect(() => renderDot(7)).not.toThrow()
    expect(() => renderDot(0, [])).not.toThrow()
  })
})
