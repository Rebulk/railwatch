import { describe, expect, it } from "vitest"

import {
  type FlameNode,
  hottestSelf,
  hottestTotal,
  layout,
  parseCollapsed,
  search,
} from "@/lib/flamegraph"

// 10 live samples across four stacks. The last three lines are the ones a
// parser has to survive: a zero-count stack, a line with no count at all,
// and a count that isn't a number.
const FIXTURE = [
  "main;Widget#index;Widget#load 3",
  "main;Widget#index;Widget#load 2",
  "main;Widget#index;render 4",
  "main;sleep 1",
  "main;Widget#index;never_ran 0",
  "main;no_count_at_all",
  "main;bad nonsense",
  "",
].join("\n")

function child(node: FlameNode, name: string): FlameNode {
  const found = node.children.find((c) => c.name === name)
  if (!found) throw new Error(`no child ${name} of ${node.name}`)
  return found
}

describe("parseCollapsed", () => {
  it("merges stacks that share a prefix under a root named all", () => {
    const root = parseCollapsed(FIXTURE)

    expect(root.name).toBe("all")
    expect(root.value).toBe(10)
    expect(root.children.map((c) => c.name)).toEqual(["main"])

    const main = child(root, "main")
    const index = child(main, "Widget#index")
    expect(main.value).toBe(10)
    expect(index.value).toBe(9)
    // The two identical Widget#load stacks became one node worth 5.
    expect(index.children.map((c) => c.name)).toEqual(["Widget#load", "render"])
    expect(child(index, "Widget#load").value).toBe(5)
  })

  it("counts a frame's own samples only where it was on top of the stack", () => {
    const root = parseCollapsed(FIXTURE)
    const index = child(child(root, "main"), "Widget#index")

    expect(child(root, "main").self).toBe(0)
    expect(index.self).toBe(0)
    expect(child(index, "Widget#load").self).toBe(5)
    expect(child(index, "render").self).toBe(4)
  })

  it("skips zero-sample and malformed lines instead of throwing", () => {
    const root = parseCollapsed(FIXTURE)
    const names = new Set<string>()
    const walk = (n: FlameNode) => {
      names.add(n.name)
      n.children.forEach(walk)
    }
    walk(root)

    expect(names.has("never_ran")).toBe(false)
    expect(names.has("no_count_at_all")).toBe(false)
    expect(names.has("bad")).toBe(false)
    expect(parseCollapsed("").value).toBe(0)
  })
})

describe("layout", () => {
  it("gives each frame a width proportional to its samples and x after its siblings", () => {
    const rects = layout(parseCollapsed(FIXTURE), 100)
    const at = (name: string) => {
      const rect = rects.find((r) => r.node.name === name)
      if (!rect) throw new Error(`no rect for ${name}`)
      return rect
    }

    expect(at("all")).toMatchObject({ x: 0, width: 100, depth: 0 })
    expect(at("main")).toMatchObject({ x: 0, width: 100, depth: 1 })
    expect(at("Widget#index")).toMatchObject({ x: 0, width: 90, depth: 2 })
    expect(at("Widget#load")).toMatchObject({ x: 0, width: 50, depth: 3 })
    expect(at("render")).toMatchObject({ x: 50, width: 40, depth: 3 })
    // sleep sits after its 90%-wide sibling, not after its parent's start.
    expect(at("sleep")).toMatchObject({ x: 90, width: 10, depth: 2 })
  })

  it("re-roots at the zoomed node so it fills the width at depth zero", () => {
    const root = parseCollapsed(FIXTURE)
    const index = child(child(root, "main"), "Widget#index")
    const rects = layout(index, 100)

    expect(rects[0]).toMatchObject({ x: 0, width: 100, depth: 0 })
    expect(rects.map((r) => r.node.name)).toEqual([
      "Widget#index",
      "Widget#load",
      "render",
    ])
    // 5 of the zoomed 9 samples.
    expect(rects[1].width).toBeCloseTo(55.56, 1)
    expect(rects[1].parentValue).toBe(9)
  })

  it("lays out an empty profile without dividing by zero", () => {
    expect(layout(parseCollapsed(""), 100)).toEqual([
      expect.objectContaining({ x: 0, width: 0, depth: 0 }),
    ])
  })
})

describe("hottestSelf / hottestTotal", () => {
  it("ranks leaves by their own samples and callers by their total", () => {
    const root = parseCollapsed(FIXTURE)

    expect(hottestSelf(root, 3)).toEqual([
      { name: "Widget#load", self: 5, total: 5 },
      { name: "render", self: 4, total: 4 },
      { name: "sleep", self: 1, total: 1 },
    ])
    expect(hottestTotal(root, 3).map((f) => [f.name, f.total])).toEqual([
      ["main", 10],
      ["Widget#index", 9],
      ["Widget#load", 5],
    ])
  })

  it("leaves the synthetic root out of the ranking", () => {
    const names = hottestTotal(parseCollapsed(FIXTURE), 20).map((f) => f.name)
    expect(names).not.toContain("all")
  })

  it("folds a frame reached through two different callers into one row", () => {
    const root = parseCollapsed(["a;log 2", "b;log 3"].join("\n"))

    expect(hottestSelf(root, 1)).toEqual([{ name: "log", self: 5, total: 5 }])
  })
})

describe("search", () => {
  it("returns the ids of every frame matching the query, case-insensitively", () => {
    const root = parseCollapsed(FIXTURE)
    const main = child(root, "main")
    const index = child(main, "Widget#index")
    const load = child(index, "Widget#load")

    expect(search(root, "widget")).toEqual(new Set([index.id, load.id]))
    expect(search(root, "RENDER")).toEqual(new Set([child(index, "render").id]))
  })

  it("matches nothing for a blank query or a miss", () => {
    const root = parseCollapsed(FIXTURE)

    expect(search(root, "   ")).toEqual(new Set())
    expect(search(root, "nope")).toEqual(new Set())
  })
})
