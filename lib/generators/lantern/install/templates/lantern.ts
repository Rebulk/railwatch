// Lantern browser client for Inertia. Reports each visit's duration,
// component, and prop payload size to /lantern/beacon so the platform can
// show real page-load timing, plus Core Web Vitals (LCP, CLS, INP, TTFB)
// for the initial page load. No dependencies -- every metric comes from
// PerformanceObserver or the navigation timing entry, and every API is
// feature-detected, so browsers missing one just report the rest.
// Batches and sends with sendBeacon on pagehide, or every 5s.
import { router } from "@inertiajs/react"

interface Visit {
  started_at: number
  url: string
  method: string
  component?: string
  duration_ms?: number
  status?: "success" | "error" | "cancelled"
  partial?: boolean
  only?: string[]
  props_bytes?: number
  lcp?: number
  cls?: number
  inp?: number
  ttfb?: number
}

const queue: Visit[] = []
let current: Visit | null = null
let initial: Visit | null = null
let finalized = false
let timer: number | undefined

function endpoint() {
  return "/lantern/beacon"
}

function csrf() {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

function flush() {
  if (queue.length === 0) return
  const body = JSON.stringify({ visits: queue.splice(0, queue.length) })
  const blob = new Blob([body], { type: "application/json" })
  if (navigator.sendBeacon?.(endpoint(), blob)) return
  fetch(endpoint(), {
    method: "POST",
    body,
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf() },
    keepalive: true,
  }).catch(() => undefined)
}

// --- Core Web Vitals ---------------------------------------------------

let lcp = 0
let cls = 0
let inp = 0
let ttfb = 0

// The entry types the observers read. lib.dom lacks the layout-shift and
// event-timing shapes (and durationThreshold), so they are declared here.
interface VitalEntry extends PerformanceEntry {
  value?: number
  hadRecentInput?: boolean
  interactionId?: number
}
interface ObserveOptions {
  durationThreshold?: number
}

function observe(type: string, callback: (entries: VitalEntry[]) => void, options: ObserveOptions = {}) {
  if (typeof PerformanceObserver === "undefined") return
  try {
    const observer = new PerformanceObserver((list) => callback(list.getEntries()))
    observer.observe({ type, buffered: true, ...options })
  } catch {
    // This browser does not support this entry type. Skip that metric only.
  }
}

function navigationEntry(): PerformanceNavigationTiming | undefined {
  const entries: PerformanceEntry[] = performance.getEntriesByType?.("navigation") ?? []
  const nav = entries[0]
  return nav instanceof PerformanceNavigationTiming ? nav : undefined
}

function startVitals() {
  const nav = navigationEntry()
  if (nav) ttfb = nav.responseStart

  // LCP: the last candidate the browser reported wins.
  observe("largest-contentful-paint", (entries) => {
    const last = entries[entries.length - 1]
    if (last) lcp = last.startTime
  })

  // CLS: the largest session window, per the web-vitals spec -- shifts with
  // no recent input, grouped by 1s gaps and capped at 5s per window.
  let sessionValue = 0
  let sessionFirst = 0
  let sessionLast = 0
  observe("layout-shift", (entries) => {
    for (const entry of entries) {
      if (entry.hadRecentInput) continue
      const value = entry.value ?? 0
      if (sessionValue && entry.startTime - sessionLast < 1000 && entry.startTime - sessionFirst < 5000) {
        sessionValue += value
        sessionLast = entry.startTime
      } else {
        sessionValue = value
        sessionFirst = entry.startTime
        sessionLast = entry.startTime
      }
      if (sessionValue > cls) cls = sessionValue
    }
  })

  // INP: the slowest interaction. The spec discards the worst few once a
  // page has 50+ interactions; a plain max is close enough here and is what
  // you want a regression alert to fire on anyway.
  observe(
    "event",
    (entries) => {
      for (const entry of entries) {
        if (entry.interactionId && entry.duration > inp) inp = entry.duration
      }
    },
    { durationThreshold: 40 },
  )
}

// The first page load is a visit too -- it just wasn't routed by Inertia, so
// the component name comes off the root element's serialized page object.
function initialVisit(): Visit | null {
  const nav = navigationEntry()
  if (!nav) return null

  let component: string | undefined
  try {
    const page = JSON.parse(document.getElementById("app")?.dataset.page ?? "{}") as { component?: string }
    component = page.component
  } catch {
    // Not an Inertia-rendered page, or the payload moved. Report it anyway.
  }

  const duration = (nav.loadEventEnd || nav.responseEnd) - nav.startTime
  return {
    started_at: Math.round((performance.timeOrigin ?? Date.now() - performance.now()) + nav.startTime),
    url: location.pathname + location.search,
    method: "GET",
    component,
    duration_ms: duration,
    status: "success",
  }
}

// Vitals keep moving until the page is backgrounded, so the initial visit is
// held back until then and shipped with its final numbers.
function finalize() {
  if (!finalized) {
    finalized = true
    if (initial) {
      initial.lcp = Math.round(lcp)
      initial.cls = Math.round(cls * 10000) / 10000
      initial.inp = Math.round(inp)
      initial.ttfb = Math.round(ttfb)
      queue.push(initial)
      initial = null
    }
  }
  // Still flushes on every later hide: a tab can be backgrounded, brought
  // back, navigated some more, and then closed.
  flush()
}

export function startLantern() {
  startVitals()
  initial = initialVisit()

  router.on("start", (event) => {
    const v = event.detail.visit
    current = {
      started_at: Date.now(),
      url: v.url.toString(),
      method: v.method,
      partial: Boolean(v.only?.length || v.except?.length),
      only: v.only,
    }
  })
  router.on("success", (event) => {
    if (!current) return
    current.component = event.detail.page.component
    current.props_bytes = JSON.stringify(event.detail.page.props ?? {}).length
    current.status = "success"
  })
  router.on("error", () => {
    if (current) current.status = "error"
  })
  router.on("finish", () => {
    if (!current) return
    current.duration_ms = Date.now() - current.started_at
    current.status ??= "cancelled"
    queue.push(current)
    current = null
    if (queue.length >= 20) flush()
  })
  timer ??= window.setInterval(flush, 5000)
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") finalize()
  })
  window.addEventListener("pagehide", finalize)
}
