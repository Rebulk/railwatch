import {
  type CSSProperties,
  type ReactNode,
  createContext,
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
} from "react"

import { Signal, type SignalAspect } from "@/components/railwatch/empty-state"
import { cn } from "@/lib/utils"

// One line of track runs under the hero: it emerges from behind the copy,
// sweeps down and left through a single bend (the Rails logo's turn), and
// runs straight along the bottom past the signal and off the right edge.
// The sweep fades to nothing as it climbs toward the words, so the train,
// which rides inside the same fade, appears out of the hero and brightens
// as it comes round the bend. On every load it tells the product's story:
// the line is clear and the product healthy as the train rolls in; as it
// stops the signal drops to red, an exception marker appears over it, and
// the product preview below flips to the failed request with its open
// issue; the exception is resolved, the signal steps to amber then green,
// the issue resolves, and the train departs off the right. One timer chain drives
// every piece; the train follows the track with CSS motion-path so it
// takes the bend itself. prefers-reduced-motion gets the clear line and no
// train.

export type Stage =
  | "arriving"
  | "approaching"
  | "braking"
  | "held"
  | "caution"
  | "clear"
  | "departed"

// The product preview under the hero follows the same stage so the story
// plays out in the product as well as on the line.
const StageContext = createContext<Stage>("departed")
export const useHeroStage = () => useContext(StageContext)

// Milliseconds after mount. The line starts clear and the product healthy;
// the train rolls in for 3.2s down the sweep and round the bend at an
// even pace. A second before it stops the environment's own status head
// in the product goes red (the app has started failing); as the train
// comes to rest the signal drops to red, the exception marker appears,
// and the product flips to the failed request. It holds, then caution,
// clear, and away.
const SCRIPT: [Stage, number][] = [
  ["approaching", 100],
  ["braking", 2300],
  ["held", 3300],
  ["caution", 6400],
  ["clear", 7200],
  ["departed", 8300],
]
const ARRIVE_MS = 3200
const DEPART_MS = 1800

const SIGNAL_FOR: Record<Stage, SignalAspect> = {
  arriving: "clear",
  approaching: "clear",
  braking: "clear",
  held: "stop",
  caution: "caution",
  clear: "clear",
  departed: "clear",
}

// `animated` is false when the story is skipped (server render, reduced
// motion): then there is no train at all, only the clear line.
function useAnimated() {
  const [animated] = useState(
    () =>
      typeof window !== "undefined" &&
      !window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  )
  return animated
}

function useStage(): { stage: Stage; animated: boolean } {
  const animated = useAnimated()
  const [stage, setStage] = useState<Stage>(animated ? "arriving" : "departed")
  useEffect(() => {
    if (!animated) return
    const timers = SCRIPT.map(([s, at]) => setTimeout(() => setStage(s), at))
    return () => timers.forEach(clearTimeout)
    // Runs once: the script is fixed and setStage is stable.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return { stage, animated }
}

// Geometry of the line in the wrapper's pixel space, measured from the
// rendered headline and strip so the sweep starts behind the copy and the
// straight run sits where the signal stands.
interface Line {
  w: number
  h: number
  p0: [number, number] // where the sweep begins, behind the copy
  c1: [number, number]
  c2: [number, number]
  p3: [number, number] // top of the bend, heading straight down
  xL: number
  yL: number
  r: number
  cx: number
  xSignal: number
  yFadeTop: number // sweep is invisible here...
  yFadeFull: number // ...and fully drawn from here down
  stop: number // offset-distance where the train is held at the signal
  total: number // offset-distance at the right edge
}

const BEND = 72 // bend radius, about five times the gauge like the logo
const GAUGE = 13.5
const TRAIN_LEN = 112
const SIGNAL_GAP = 14

function bezierLength(
  p0: [number, number],
  c1: [number, number],
  c2: [number, number],
  p3: [number, number],
) {
  let len = 0
  let [px, py] = p0
  for (let i = 1; i <= 64; i++) {
    const t = i / 64
    const u = 1 - t
    const x =
      u * u * u * p0[0] +
      3 * u * u * t * c1[0] +
      3 * u * t * t * c2[0] +
      t * t * t * p3[0]
    const y =
      u * u * u * p0[1] +
      3 * u * u * t * c1[1] +
      3 * u * t * t * c2[1] +
      t * t * t * p3[1]
    len += Math.hypot(x - px, y - py)
    px = x
    py = y
  }
  return len
}

function measure(el: HTMLDivElement): Line | null {
  const h1 = el.querySelector("h1")
  const strip = el.querySelector<HTMLElement>("[data-hero-strip]")
  if (!h1 || !strip) return null
  const box = el.getBoundingClientRect()
  const hb = h1.getBoundingClientRect()
  const sb = strip.getBoundingClientRect()
  const w = box.width
  const h = box.height
  const phone = w < 768
  const cx = w / 2
  const xL = phone ? 10 : Math.max(16, cx - 520)
  const yL = sb.top - box.top + 60
  const r = BEND
  const xSignal = cx + (phone ? 120 : 220)
  // The sweep starts just under the headline, a little left of centre, and
  // leaves heading down-left; it arrives at the bend heading straight down.
  const p0: [number, number] = [
    cx - (phone ? 30 : 60),
    hb.top - box.top + hb.height + 4,
  ]
  const p3: [number, number] = [xL, yL - r]
  const drop = p3[1] - p0[1]
  const c1: [number, number] = [p0[0] - drop * 0.55, p0[1] + drop * 0.32]
  const c2: [number, number] = [xL, p3[1] - drop * 0.42]
  const sweep = bezierLength(p0, c1, c2, p3)
  const quarter = (Math.PI * r) / 2
  const stopX = xSignal - SIGNAL_GAP - TRAIN_LEN / 2
  const stop = sweep + quarter + (stopX - (xL + r))
  const total = sweep + quarter + (w + TRAIN_LEN + 40 - (xL + r))
  return {
    w,
    h,
    p0,
    c1,
    c2,
    p3,
    xL,
    yL,
    r,
    cx,
    xSignal,
    yFadeTop: p0[1],
    yFadeFull: p0[1] + drop * 0.7,
    stop,
    total,
  }
}

// The centreline, offset by `inset` for the two rails (positive = outside
// the bend, negative = inside).
function linePath(g: Line, inset: number) {
  const [x0, y0] = g.p0
  const r = g.r + inset
  // Offsetting a bezier exactly is not worth it at this width; nudge the
  // endpoints and control points perpendicular to the travel direction.
  const nx = inset
  const d = [
    `M ${x0 + nx * 0.5} ${y0 - nx * 0.85}`,
    `C ${g.c1[0] + nx * 0.5} ${g.c1[1] - nx * 0.85}, ${g.c2[0] - inset} ${g.c2[1]}, ${g.p3[0] - inset} ${g.p3[1]}`,
    `A ${r} ${r} 0 0 0 ${g.xL + g.r} ${g.yL + inset}`,
    `L ${g.w + TRAIN_LEN + 40} ${g.yL + inset}`,
  ]
  return d.join(" ")
}

// Plan view of a short train as three cars. Each car is centred on the
// origin and pointing +x, and rides the same motion path as the others at
// its own distance along it (CARS), so round the bend every car sits on
// the rails and turns on its own rather than the whole train poking out
// of the curve as one rigid body. The gold cab marker rides the leading
// car; the exception diamond sits over the middle one.
const CARS = [
  { at: -41, w: 30 },
  { at: -4, w: 34 },
  { at: 37, w: 38 },
] as const
const CAB = CARS.length - 1
const MIDDLE = 1

function Car({
  index,
  held,
  style,
}: {
  index: number
  held: boolean
  style: CSSProperties | undefined
}) {
  const car = CARS[index]
  return (
    <g className="text-foreground/85" style={style}>
      <rect
        x={-car.w / 2}
        y="-7"
        width={car.w}
        height="14"
        rx="3"
        fill="currentColor"
      />
      {index === CAB && (
        <rect
          x={car.w / 2 - 6}
          y="-4"
          width="4"
          height="8"
          rx="1"
          className="text-primary"
          fill="currentColor"
        />
      )}
      {index === MIDDLE && (
        /* The exception: the same red diamond the timeline uses for one. */
        <rect
          x="-5"
          y="-25"
          width="10"
          height="10"
          transform="rotate(45 0 -20)"
          className={cn(
            "transition-opacity duration-300",
            held ? "opacity-100" : "opacity-0",
          )}
          fill="rgb(239 68 68)"
        />
      )}
    </g>
  )
}

export function HeroStageProvider({ children }: { children: ReactNode }) {
  const { stage } = useStage()
  return <StageContext.Provider value={stage}>{children}</StageContext.Provider>
}

export function HeroLoop({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null)
  const [line, setLine] = useState<Line | null>(null)
  const stage = useHeroStage()
  const animated = useAnimated()
  const maskId = useId()

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const update = () => setLine(measure(el))
    update()
    const ro = new ResizeObserver(update)
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const held = stage === "held"

  // Where the train's centre is along the path in each stage, and how it
  // gets there. Each car adds its own CARS[i].at to the distance, with the
  // same transition, so the cars move as one and each takes the bend.
  let target: { distance: number; transition?: string } | undefined
  if (line) {
    switch (stage) {
      case "arriving":
        target = { distance: 0 }
        break
      case "approaching":
      case "braking":
      case "held":
      case "caution":
        target = {
          distance: line.stop,
          transition: `offset-distance ${ARRIVE_MS}ms cubic-bezier(.45,.05,.25,1)`,
        }
        break
      case "clear":
        target = {
          distance: line.stop + 120,
          transition: "offset-distance 900ms ease-in-out",
        }
        break
      case "departed":
        target = {
          distance: line.total,
          transition: `offset-distance ${DEPART_MS}ms cubic-bezier(.4,0,.8,.6)`,
        }
        break
    }
  }
  const carStyle = (index: number): CSSProperties | undefined =>
    line && target
      ? {
          offsetPath: `path("${linePath(line, 0)}")`,
          offsetRotate: "auto",
          offsetDistance: `${target.distance + CARS[index].at}px`,
          transition: target.transition,
        }
      : undefined

  return (
    <div ref={ref} className="relative overflow-hidden">
      {line && (
        <svg
          aria-hidden
          className="text-foreground/30 pointer-events-none absolute inset-0 z-0 h-full w-full [mask-image:linear-gradient(to_right,black_86%,transparent)]"
          width={line.w}
          height={line.h}
          viewBox={`0 0 ${line.w} ${line.h}`}
        >
          <defs>
            {/* The sweep fades out as it rises toward the copy; the train
                rides inside the same mask so it fades in by position. */}
            <linearGradient
              id={`${maskId}-fade`}
              gradientUnits="userSpaceOnUse"
              x1="0"
              y1={line.yFadeTop}
              x2="0"
              y2={line.yFadeFull}
            >
              <stop offset="0" stopColor="white" stopOpacity="0" />
              <stop offset="1" stopColor="white" stopOpacity="1" />
            </linearGradient>
            <mask
              id={maskId}
              maskUnits="userSpaceOnUse"
              x="0"
              y="0"
              width={line.w}
              height={line.h}
            >
              <rect
                width={line.w}
                height={line.h}
                fill={`url(#${maskId}-fade)`}
              />
            </mask>
          </defs>
          <g mask={`url(#${maskId})`}>
            {/* Ties: the centreline stroked tie-length wide and dashed. */}
            <path
              d={linePath(line, 0)}
              fill="none"
              stroke="currentColor"
              strokeWidth="30"
              strokeDasharray="4 18"
            />
            <path
              d={linePath(line, GAUGE / 2)}
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
            />
            <path
              d={linePath(line, -GAUGE / 2)}
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
            />
            {animated &&
              CARS.map((_, index) => (
                <Car
                  key={index}
                  index={index}
                  held={held}
                  style={carStyle(index)}
                />
              ))}
          </g>
        </svg>
      )}
      <div className="relative z-10">{children}</div>
      {line && (
        <>
          <div
            className="pointer-events-none absolute z-10 h-0 w-0"
            style={{ left: line.xSignal, top: line.yL }}
            aria-hidden
          >
            <Signal aspect={SIGNAL_FOR[stage]} className="left-0 md:left-0" />
          </div>
        </>
      )}
    </div>
  )
}
