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

// The tab's session, for release health. sessionStorage scopes it to the
// tab and it dies with the tab, which is what a browser session is.
interface Session {
  id: string
  started_at: number
  duration_ms?: number
  ended?: boolean
}

const SESSION_ID_KEY = "lantern.session"
const SESSION_STARTED_KEY = "lantern.session.at"

const queue: Visit[] = []
let current: Visit | null = null
let initial: Visit | null = null
let session: Session | null = null
let finalized = false
let timer: number | undefined

function endpoint() {
  return "/lantern/beacon"
}

function csrf() {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

function post(payload: { visits: Visit[]; session?: Session }) {
  const body = JSON.stringify(payload)
  const blob = new Blob([body], { type: "application/json" })
  if (navigator.sendBeacon?.(endpoint(), blob)) return
  fetch(endpoint(), {
    method: "POST",
    body,
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf() },
    keepalive: true,
  }).catch(() => undefined)
}

function flush(ended = false) {
  if (queue.length === 0 && !ended) return
  post({ visits: queue.splice(0, queue.length), session: beat(ended) })
}

// --- Session -----------------------------------------------------------

function randomId() {
  const bytes = new Uint8Array(8)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")
}

// Mints the tab's session on its first load, or picks up the one an earlier
// page in this tab minted, and mirrors the id into a cookie so every request
// the tab makes carries it -- that is what lets the server side of the
// session (Lantern::Sessions) join the browser side under one id.
function startSession() {
  try {
    const existing = sessionStorage.getItem(SESSION_ID_KEY)
    const id = existing ?? randomId()
    const startedAt = Number(sessionStorage.getItem(SESSION_STARTED_KEY)) || Date.now()
    if (!existing) {
      sessionStorage.setItem(SESSION_ID_KEY, id)
      sessionStorage.setItem(SESSION_STARTED_KEY, String(startedAt))
    }
    document.cookie = `lantern_session=${id}; path=/; SameSite=Lax`
    session = { id, started_at: startedAt }
    // No duration on the first beat: that is what opens the session.
    if (!existing) post({ visits: [], session: { ...session } })
  } catch {
    // sessionStorage is unavailable (private mode, storage disabled).
    // Everything else still reports; this tab just has no session.
  }
}

function beat(ended: boolean): Session | undefined {
  if (!session) return undefined
  return { ...session, duration_ms: Date.now() - session.started_at, ended }
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

// Guarded by entryType rather than `instanceof PerformanceNavigationTiming`:
// that constructor is a bare global that jsdom (and any non-browser runtime
// this file is imported into) does not define, and a ReferenceError here
// would take the whole client down with it.
function navigationEntry(): PerformanceNavigationTiming | undefined {
  const entries: PerformanceEntry[] = performance.getEntriesByType?.("navigation") ?? []
  const nav = entries[0]
  return nav?.entryType === "navigation" ? (nav as PerformanceNavigationTiming) : undefined
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
  // back, navigated some more, and then closed. Each of those carries a
  // final session beat, which the platform dedupes by session id.
  flush(true)
}

export function startLantern() {
  startVitals()
  startSession()
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
