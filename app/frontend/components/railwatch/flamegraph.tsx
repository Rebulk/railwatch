import { useEffect, useMemo, useRef, useState } from "react"

import { DataTable } from "@/components/railwatch/data-table"
import { Segmented, SegmentedItem } from "@/components/railwatch/segmented"
import { Input } from "@/components/ui/input"
import {
  type FlameNode,
  type FlameRect,
  hottestSelf,
  hottestTotal,
  layout,
  parseCollapsed,
  search,
} from "@/lib/flamegraph"
import { count, pct } from "@/lib/format"
import { cn } from "@/lib/utils"

const ROW = 18
const HOTTEST = 15

interface View {
  tree: FlameNode
  zoom: FlameNode[]
  hovered: { rect: FlameRect; x: number; y: number } | null
}

// Frames read "Class#method (path:line)". The gem strips the Rails root
// from app paths, so an app frame's path starts with app/, lib/ or config/;
// a gem frame's path starts with the gem's name (activerecord/...), Ruby's
// own with ruby/ or <internal:, and a C function has no file at all. Only
// the app's own frames get the warm end of the palette.
function isAppFrame(name: string): boolean {
  const open = name.lastIndexOf(" (")
  const path = open >= 0 ? name.slice(open + 2) : ""
  return /^(app|lib|config|db|engines)\//.test(path)
}

function hashOf(value: string): number {
  let h = 0
  for (let i = 0; i < value.length; i++) h = (h * 31 + value.charCodeAt(i)) | 0
  return Math.abs(h)
}

// Colour is a stable hash of the frame name so the same frame keeps the same
// shade between renders and between profiles — warm oranges/ambers for app
// frames, desaturated slate for everything else.
function frameColor(name: string): string {
  const h = hashOf(name)
  return isAppFrame(name)
    ? `hsl(${[24, 34, 14, 44, 4][h % 5]} 78% ${52 + (h % 3) * 6}%)`
    : `hsl(${[215, 220, 210][h % 3]} 14% ${58 + (h % 3) * 7}%)`
}

function truncate(name: string, width: number): string {
  const chars = Math.floor((width - 8) / 5.6)
  if (chars < 4) return ""
  return name.length <= chars ? name : name.slice(0, chars - 1) + "…"
}

function Tooltip({
  rect,
  total,
  x,
  y,
}: {
  rect: FlameRect
  total: number
  x: number
  y: number
}) {
  return (
    <div
      className="bg-popover text-popover-foreground pointer-events-none absolute z-10 max-w-[min(22rem,90vw)] rounded-md border p-2 shadow-md"
      style={{ left: Math.max(0, x - 8), top: y + 14 }}
    >
      <div className="font-mono text-[11px] break-all">{rect.node.name}</div>
      <div className="text-muted-foreground mt-1 flex flex-wrap gap-x-3 font-mono text-[10px] tabular-nums">
        <span>{count(rect.node.value)} samples</span>
        <span>{pct(rect.node.value, total)} of total</span>
        <span>{pct(rect.node.value, rect.parentValue)} of parent</span>
        {rect.node.self > 0 && <span>{count(rect.node.self)} self</span>}
      </div>
    </div>
  )
}

// An icicle chart (root on top, callees below) over collapsed stacks. Click
// a frame to zoom into it; the breadcrumb walks back out.
export function Flamegraph({
  collapsed,
  className,
}: {
  collapsed: string
  className?: string
}) {
  const tree = useMemo(() => parseCollapsed(collapsed), [collapsed])
  const [query, setQuery] = useState("")
  const [mode, setMode] = useState<"self" | "total">("self")
  // Zoom path and hover both point at nodes of one particular tree, so they
  // are stored with it: a new profile makes the whole view stale at once,
  // without an effect that resets them a render late.
  const [state, setState] = useState<View>({ tree, zoom: [], hovered: null })
  const view = state.tree === tree ? state : { tree, zoom: [], hovered: null }
  const zoom = view.zoom

  const containerRef = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(0)

  useEffect(() => {
    const el = containerRef.current
    if (!el) return
    setWidth(el.clientWidth)
    const observer = new ResizeObserver(([entry]) =>
      setWidth(entry.contentRect.width),
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  const root = zoom[zoom.length - 1] ?? tree
  const rects = useMemo(() => layout(root, width), [root, width])
  const matches = useMemo(() => search(tree, query), [tree, query])
  const hottest = useMemo(
    () =>
      mode === "self"
        ? hottestSelf(root, HOTTEST)
        : hottestTotal(root, HOTTEST),
    [root, mode],
  )

  const depth = rects.reduce((max, r) => Math.max(max, r.depth), 0)
  const searching = matches.size > 0

  if (tree.value === 0) {
    return (
      <p className="text-muted-foreground py-6 text-center text-sm">
        This profile recorded no samples.
      </p>
    )
  }

  return (
    <div className={cn("space-y-3", className)}>
      <div className="flex flex-wrap items-center gap-2">
        <Input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search frames"
          className="h-8 max-w-56 font-mono text-xs"
          aria-label="Search frames"
        />
        {query !== "" && (
          <span className="text-muted-foreground font-mono text-[11px]">
            {matches.size} match{matches.size === 1 ? "" : "es"}
          </span>
        )}
        <div className="ml-auto flex flex-wrap items-center gap-1 font-mono text-[11px]">
          {[tree, ...zoom].map((node, i) => (
            <span key={node.id} className="flex items-center gap-1">
              {i > 0 && <span className="text-muted-foreground">/</span>}
              <button
                type="button"
                onClick={() => setState({ ...view, zoom: zoom.slice(0, i) })}
                disabled={i === zoom.length}
                className={cn(
                  "max-w-40 truncate",
                  i === zoom.length
                    ? "text-foreground font-semibold"
                    : "text-muted-foreground hover:underline",
                )}
              >
                {node.name}
              </button>
            </span>
          ))}
        </div>
      </div>

      <div
        ref={containerRef}
        className="bg-muted/20 relative overflow-hidden rounded-lg border"
        onMouseLeave={() => setState({ ...view, hovered: null })}
      >
        <svg
          width={width}
          height={(depth + 1) * ROW}
          role="img"
          aria-label={`Flamegraph of ${tree.value} samples`}
        >
          {rects.map((r) => {
            const label = truncate(r.node.name, r.width)
            return (
              <g
                key={r.id}
                onClick={() =>
                  setState({
                    ...view,
                    zoom: [...zoom, ...pathTo(root, r.node)],
                  })
                }
                onMouseMove={(e) => {
                  const box = containerRef.current?.getBoundingClientRect()
                  setState({
                    ...view,
                    hovered: {
                      rect: r,
                      x: e.clientX - (box?.left ?? 0),
                      y: e.clientY - (box?.top ?? 0),
                    },
                  })
                }}
                className="cursor-pointer"
              >
                <rect
                  x={r.x}
                  y={r.depth * ROW}
                  width={Math.max(0, r.width - 1)}
                  height={ROW - 1}
                  rx={2}
                  fill={frameColor(r.node.name)}
                  opacity={
                    searching
                      ? matches.has(r.id)
                        ? 1
                        : 0.18
                      : view.hovered?.rect.id === r.id
                        ? 1
                        : 0.88
                  }
                  stroke={matches.has(r.id) ? "currentColor" : "none"}
                  strokeWidth={1}
                />
                {label !== "" && (
                  <text
                    x={r.x + 4}
                    y={r.depth * ROW + ROW / 2}
                    dominantBaseline="central"
                    className="pointer-events-none fill-black/85 font-mono text-[10px]"
                  >
                    {label}
                  </text>
                )}
              </g>
            )
          })}
        </svg>
        {view.hovered && (
          <Tooltip
            rect={view.hovered.rect}
            total={tree.value}
            x={view.hovered.x}
            y={view.hovered.y}
          />
        )}
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="label-caps">Hottest frames</h3>
        <Segmented>
          <SegmentedItem
            active={mode === "self"}
            onClick={() => setMode("self")}
          >
            Self
          </SegmentedItem>
          <SegmentedItem
            active={mode === "total"}
            onClick={() => setMode("total")}
          >
            Total
          </SegmentedItem>
        </Segmented>
      </div>
      <DataTable
        rows={hottest}
        rowKey={(f) => f.name}
        empty="No frames in this view."
        columns={[
          {
            key: "name",
            header: "Frame",
            className: "max-w-0",
            cell: (f) => (
              <span className="block truncate font-mono text-xs" title={f.name}>
                {f.name}
              </span>
            ),
          },
          {
            key: "self",
            header: "Self",
            align: "right",
            cell: (f) => (
              <span className={mode === "self" ? "font-semibold" : ""}>
                {count(f.self)}
              </span>
            ),
          },
          {
            key: "total",
            header: "Total",
            align: "right",
            cell: (f) => (
              <span className={mode === "total" ? "font-semibold" : ""}>
                {count(f.total)}
              </span>
            ),
          },
        ]}
      />
    </div>
  )
}

// The chain of nodes from the current root down to `target`, so clicking a
// frame deep in the graph pushes every step onto the breadcrumb.
function pathTo(from: FlameNode, target: FlameNode): FlameNode[] {
  if (from === target) return []
  for (const child of from.children) {
    const rest = pathTo(child, target)
    if (rest.length > 0 || child === target) return [child, ...rest]
  }
  return []
}
