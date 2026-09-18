// Collapsed stacks ("outer;inner;leaf count\n", the format stackprof and
// vernier both fold to) turned into the tree and rectangles the flamegraph
// component draws. Pure data — no React, no DOM — so the layout maths is
// unit-testable on its own.

export interface FlameNode {
  id: number
  name: string
  // Samples in this frame and everything it called.
  value: number
  // Samples where this frame was on top of the stack.
  self: number
  children: FlameNode[]
}

export interface FlameRect {
  id: number
  node: FlameNode
  x: number
  width: number
  depth: number
  // The value of the enclosing frame, for the tooltip's "% of parent".
  parentValue: number
}

export interface FrameStat {
  name: string
  self: number
  total: number
}

// Parses collapsed stacks into a tree rooted at a synthetic "all" frame,
// merging every stack that shares a prefix. Lines without a trailing sample
// count, with a non-numeric or non-positive count, or with no frames at all
// are skipped rather than throwing: a profile is a best-effort artefact and
// one bad line should not blank the page.
export function parseCollapsed(text: string): FlameNode {
  let nextId = 0
  const make = (name: string): FlameNode => ({
    id: nextId++,
    name,
    value: 0,
    self: 0,
    children: [],
  })

  const root = make("all")
  const index = new Map<string, FlameNode>()

  for (const raw of text.split("\n")) {
    const line = raw.trim()
    const sep = line.lastIndexOf(" ")
    if (sep <= 0) continue
    const count = Number(line.slice(sep + 1))
    if (!Number.isFinite(count) || count <= 0) continue
    const frames = line
      .slice(0, sep)
      .split(";")
      .filter((f) => f.length > 0)
    if (frames.length === 0) continue

    root.value += count
    let current = root
    let path = ""
    for (const name of frames) {
      path += ";" + name
      let child = index.get(path)
      if (!child) {
        child = make(name)
        current.children.push(child)
        index.set(path, child)
      }
      child.value += count
      current = child
    }
    current.self += count
  }
  return root
}

// x/width for every node, proportional to its share of `root`, with depth
// counted from the given root — so zooming is just calling this again with
// the clicked node.
export function layout(root: FlameNode, width: number): FlameRect[] {
  const rects: FlameRect[] = []
  const scale = root.value > 0 ? width / root.value : 0

  const walk = (node: FlameNode, x: number, depth: number, parent: number) => {
    rects.push({
      id: node.id,
      node,
      x,
      width: node.value * scale,
      depth,
      parentValue: parent,
    })
    let childX = x
    for (const child of node.children) {
      walk(child, childX, depth + 1, node.value)
      childX += child.value * scale
    }
  }

  walk(root, 0, 0, root.value)
  return rects
}

// Same frame can appear under many callers; the hottest-frames table folds
// them by name the way stackprof's own report does. The synthetic root is
// left out — "all" is never an interesting frame.
function byName(root: FlameNode): Map<string, FrameStat> {
  const stats = new Map<string, FrameStat>()
  const walk = (node: FlameNode, isRoot: boolean) => {
    if (!isRoot) {
      const stat = stats.get(node.name) ?? {
        name: node.name,
        self: 0,
        total: 0,
      }
      stat.self += node.self
      stat.total += node.value
      stats.set(node.name, stat)
    }
    for (const child of node.children) walk(child, false)
  }
  walk(root, true)
  return stats
}

export function hottestSelf(root: FlameNode, n: number): FrameStat[] {
  return [...byName(root).values()]
    .sort((a, b) => b.self - a.self || b.total - a.total)
    .slice(0, n)
}

export function hottestTotal(root: FlameNode, n: number): FrameStat[] {
  return [...byName(root).values()]
    .sort((a, b) => b.total - a.total || b.self - a.self)
    .slice(0, n)
}

// Ids of every node whose frame name contains `query`, case-insensitively.
// A blank query matches nothing rather than everything, so clearing the box
// clears the highlight.
export function search(root: FlameNode, query: string): Set<number> {
  const matches = new Set<number>()
  const needle = query.trim().toLowerCase()
  if (needle === "") return matches
  const walk = (node: FlameNode) => {
    if (node.name.toLowerCase().includes(needle)) matches.add(node.id)
    for (const child of node.children) walk(child)
  }
  walk(root)
  return matches
}
