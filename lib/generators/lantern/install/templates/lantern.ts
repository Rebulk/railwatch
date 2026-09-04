// Lantern browser client for Inertia. Reports each visit's duration,
// component, and prop payload size to /lantern/beacon so the platform can
// show real page-load timing, plus Core Web Vitals (LCP, CLS, INP, TTFB)
// for the initial page load, plus every JavaScript error the page throws
// with the breadcrumb trail that led to it.
// No dependencies -- every metric comes from PerformanceObserver or the
// navigation timing entry, and every API is feature-detected, so browsers
// missing one just report the rest.
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

// A JavaScript error the page threw, with the stack exactly as the browser
// wrote it -- the server parses it into frames.
interface JsError {
  at: number
  name: string
  message: string
  stack?: string
  component?: string
  url: string
  visit?: string
  breadcrumbs?: Crumb[]
  context?: Record<string, unknown>
}

// What the user did in the run-up to a crash. The same idea as the server
// side's breadcrumbs, which are what the execution did before it raised.
interface Crumb {
  at: number
  kind: "console" | "click" | "navigate"
  text: string
}

export interface LanternOptions {
  // Messages that are never worth an issue, added to the defaults below. A
  // string matches anywhere in the message; a regex is tested against it.
  ignoreErrors?: (string | RegExp)[]
  // Scripts whose failures are not this app's to fix, added to the defaults
  // below and matched against the top stack frame's URL.
  denyUrls?: RegExp[]
  // The tenant the user is looking at. The beacon posts to /lantern/beacon,
  // which is outside whatever path or subdomain the app scopes tenants by,
  // so the server cannot work this out for itself. Read on every flush, so
  // it follows the user across tenants without a page load.
  tenant?: () => string | undefined
}

// Browser noise that is never actionable: ResizeObserver fires from benign
// layout thrash and the spec says to ignore it, and the extension URLs are
// third-party code running in someone's browser that this app cannot fix.
const DEFAULT_IGNORE_ERRORS = [
  "ResizeObserver loop limit exceeded",
  "ResizeObserver loop completed with undelivered notifications",
]
const DEFAULT_DENY_URLS = [/extensions\//i, /^chrome:\/\//i, /^moz-extension:\/\//i]

const SESSION_ID_KEY = "lantern.session"
const SESSION_STARTED_KEY = "lantern.session.at"

const queue: Visit[] = []
const errors: JsError[] = []
const crumbs: Crumb[] = []
let current: Visit | null = null
let initial: Visit | null = null
let session: Session | null = null
// The Inertia page component the user is on, so an error that fires between
// visits still says which screen it broke.
let component: string | undefined
let finalized = false
let timer: number | undefined
let ignoreErrors: (string | RegExp)[] = DEFAULT_IGNORE_ERRORS
let denyUrls: RegExp[] = DEFAULT_DENY_URLS
let tenantOf: (() => string | undefined) | undefined

function endpoint() {
  return "/lantern/beacon"
}

function csrf() {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

function post(payload: { visits: Visit[]; errors: JsError[]; session?: Session; tenant?: string }) {
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
  if (queue.length === 0 && errors.length === 0 && !ended) return
  post({ visits: queue.splice(0, queue.length), errors: errors.splice(0, errors.length), session: beat(ended), tenant: tenant() })
}

// The app's tenant resolver runs on the flush path, where a throw would cost
// the whole batch, so it never gets to.
function tenant() {
  try {
    return tenantOf?.()
  } catch {
    // The app's resolver raised. These records just carry no tenant.
    return undefined
  }
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
    if (!existing) post({ visits: [], errors: [], session: { ...session }, tenant: tenant() })
  } catch {
    // sessionStorage is unavailable (private mode, storage disabled).
    // Everything else still reports; this tab just has no session.
  }
}

function beat(ended: boolean): Session | undefined {
  if (!session) return undefined
  return { ...session, duration_ms: Date.now() - session.started_at, ended }
}

// --- Breadcrumbs -------------------------------------------------------

const MAX_CRUMBS = 20
const MAX_CRUMB_TEXT = 500
// A budget for one error's whole trail, so a page that logs War and Peace to
// the console cannot crowd out the errors themselves.
const MAX_CRUMB_BYTES = 8000

function crumb(kind: Crumb["kind"], text: string) {
  if (!text) return
  crumbs.push({ at: Date.now(), kind, text: text.slice(0, MAX_CRUMB_TEXT) })
  if (crumbs.length > MAX_CRUMBS) crumbs.shift()
}

// The trail as it stood when an error fired, oldest first, giving up its
// oldest entries until it fits the byte budget.
function trail(): Crumb[] {
  const taken = crumbs.slice()
  while (taken.length > 0 && JSON.stringify(taken).length > MAX_CRUMB_BYTES) taken.shift()
  return taken
}

// "button#save.btn.primary "Save order"" -- enough to recognise what was
// clicked, and never an input's value, which is the user's data and not
// ours to ship.
function describeTarget(target: EventTarget | null): string {
  if (!(target instanceof Element)) return ""
  const id = target.id ? `#${target.id}` : ""
  const className = typeof target.className === "string" ? target.className.trim() : ""
  const classes = className ? `.${className.split(/\s+/).join(".")}` : ""
  const text = target instanceof HTMLInputElement ? "" : (target.textContent ?? "").trim().replace(/\s+/g, " ").slice(0, 80)
  return `${target.tagName.toLowerCase()}${id}${classes}${text ? ` "${text}"` : ""}`
}

function startBreadcrumbs() {
  document.addEventListener("click", (event) => crumb("click", describeTarget(event.target)), true)
  for (const level of ["error", "warn"] as const) {
    const original = console[level].bind(console) as (...args: unknown[]) => void
    console[level] = (...args: unknown[]) => {
      crumb("console", `${level}: ${args.map(stringify).join(" ")}`)
      original(...args)
    }
  }
}

// --- JavaScript errors -------------------------------------------------

const MAX_MESSAGE = 1000
const MAX_STACK = 8000
// The server caps a beacon at 50 errors too. This is what stops a component
// that throws on every render from growing the queue without bound between
// flushes.
const MAX_ERRORS = 50

// The script a stack line points at: a URL or a bare path, followed by the
// line (and column) every engine appends. Anchored to the end of the line so
// a path quoted in the error's own message is not mistaken for a frame.
const FRAME_URL = /((?:[a-z][a-z0-9+.-]*:\/\/|\/)[^\s()'"]+):\d+(?::\d+)?\)?$/i

function topFrameUrl(stack: string): string | undefined {
  for (const line of stack.split("\n")) {
    const match = FRAME_URL.exec(line.trim())
    if (match) return match[1]
  }
  return undefined
}

// Everything that gets an error dropped before it costs a beacon: a message
// the app said it never wants, a denied script, or a top frame that is not
// the app's own code at all -- an extension, an injected widget, a tag
// manager. None of those are anything this app can fix.
function ignored(message: string, stack?: string): boolean {
  if (ignoreErrors.some((pattern) => (typeof pattern === "string" ? message.includes(pattern) : pattern.test(message)))) return true
  const url = stack ? topFrameUrl(stack) : undefined
  if (!url) return false
  if (denyUrls.some((pattern) => pattern.test(url))) return true
  return !url.startsWith("/") && !url.startsWith(`${location.origin}/`)
}

function capture(name: string, message: string, stack?: string, context?: Record<string, unknown>) {
  if (errors.length >= MAX_ERRORS) return
  if (ignored(message, stack)) return
  const breadcrumbs = trail()
  const error: JsError = {
    at: Date.now(),
    name: name.slice(0, 200) || "Error",
    message: message.slice(0, MAX_MESSAGE),
    stack: stack?.slice(0, MAX_STACK),
    component,
    url: location.pathname + location.search,
    visit: current?.url,
    breadcrumbs: breadcrumbs.length > 0 ? breadcrumbs : undefined,
    context,
  }
  // Deduped within the flush, not across the page's life: a render loop
  // throws the same error every retry, and Inertia re-rejects the error it
  // just fired `exception` for, so the same crash arrives twice.
  if (errors.some((e) => e.name === error.name && e.message === error.message && e.stack === error.stack)) return
  errors.push(error)
}

// Anything at all can be thrown or rejected in JavaScript, not just an
// Error. A non-Error value is reported under `fallback` with whatever it
// stringifies to as the message.
function captureValue(value: unknown, fallback: string, context?: Record<string, unknown>) {
  if (value instanceof Error) capture(value.name, value.message, value.stack, context)
  else capture(fallback, stringify(value), undefined, context)
}

// An error the app caught itself. On React 18, whose roots take no error
// options, this is how a boundary reports what it caught -- and it has to,
// because a production React 18 build does not re-throw a caught error to
// window.onerror:
//
//   componentDidCatch(error: Error, info: ErrorInfo) {
//     reportError(error, { componentStack: info.componentStack })
//   }
export function reportError(error: unknown, context?: Record<string, unknown>) {
  captureValue(error, "Error", context)
}

// React 19's root error options, for `createRoot(el, lanternRootOptions())`.
//
// onCaughtError is the one that matters: an error a boundary catches goes to
// console.error and no further, so without this every render error a
// boundary handles is invisible in production. onUncaughtError would reach
// the window listener on its own (React's default hands it to
// window.reportError), but taking it here attaches the component stack,
// which exists nowhere else. onRecoverableError is deliberately left to
// React: its default also goes through window.reportError, so a hydration
// mismatch already arrives, and overriding it would take React's own
// console warning away from whoever is debugging one.
interface ReactErrorInfo {
  componentStack?: string | null
}

export function lanternRootOptions(): {
  onCaughtError: (error: unknown, info: ReactErrorInfo) => void
  onUncaughtError: (error: unknown, info: ReactErrorInfo) => void
} {
  const report = (error: unknown, info: ReactErrorInfo) =>
    captureValue(error, "Error", info.componentStack ? { componentStack: info.componentStack } : undefined)
  return { onCaughtError: report, onUncaughtError: report }
}

function stringify(value: unknown) {
  try {
    return String(value)
  } catch {
    // A Symbol, or an object whose toString throws.
    return `<${typeof value}>`
  }
}

// Every route a JavaScript error can take to get here. A failed Inertia
// request has two: the request itself threw (a dropped connection arrives
// as an axios "Network Error"), or the server answered with something that
// was not an Inertia response at all -- a 403 page from an authorization
// filter, a login redirect, an error page from a proxy. Inertia 2 calls
// those `exception` and `invalid`; Inertia 3 renamed them `networkError`
// and `httpException`. Both versions dispatch every router event as a
// CustomEvent "inertia:<name>" on document, so listening there for all
// four names works on either without the typed router.on, whose event map
// only knows its own version's names.
function startErrorCapture() {
  window.addEventListener("error", (event) => {
    // Neither an error object nor a message means there is nothing to
    // report -- a failed <img> or <script> load, not a JavaScript error.
    if (!event.error && !event.message) return
    captureValue((event.error ?? event.message) as unknown, "Error")
  })
  window.addEventListener("unhandledrejection", (event) => {
    captureValue(event.reason as unknown, "UnhandledRejection")
  })
  onInertia("exception", (detail) => captureValue(detail.exception, "InertiaException"))
  onInertia("networkError", (detail) => captureValue(detail.error, "InertiaException"))
  onInertia("invalid", (detail) => captureInvalidResponse(detail.response))
  onInertia("httpException", (detail) => captureInvalidResponse(detail.response))
}

function onInertia(name: string, handler: (detail: Record<string, unknown>) => void) {
  document.addEventListener(`inertia:${name}`, (event) => {
    const detail = (event as CustomEvent<unknown>).detail
    handler(typeof detail === "object" && detail !== null ? (detail as Record<string, unknown>) : {})
  })
}

// A response Inertia could not apply: an auth redirect's HTML, a 404 page,
// a proxy error. Inertia 3's httpException ALSO fires for a perfectly valid
// Inertia response carrying a 4xx status -- a form re-rendered with
// validation errors at 422, a not-found page the app renders on purpose --
// and those are the app working as designed, not errors. Inertia's own
// predicate for the two cases is the x-inertia response header, so that is
// the gate here; Inertia 2's `invalid` only ever fired for the first kind.
function captureInvalidResponse(response: unknown) {
  const res = (response ?? {}) as { status?: unknown; headers?: Record<string, unknown> }
  if (inertiaResponse(res.headers)) return
  const status = typeof res.status === "number" ? res.status : "unknown status"
  const contentType = res.headers?.["content-type"]
  capture("InertiaInvalidResponse", `Inertia invalid response (${status})`, undefined, {
    status,
    ...(typeof contentType === "string" ? { content_type: contentType } : {}),
  })
}

function inertiaResponse(headers: Record<string, unknown> | undefined): boolean {
  if (!headers || typeof headers !== "object") return false
  return Object.keys(headers).some((key) => key.toLowerCase() === "x-inertia" && headers[key])
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

// The component the server rendered this page with, off the root element's
// serialized page object. Inertia's own events take over from here.
function pageComponent(): string | undefined {
  try {
    const page = JSON.parse(document.getElementById("app")?.dataset.page ?? "{}") as { component?: string }
    return page.component
  } catch {
    // Not an Inertia-rendered page, or the payload moved. Report it anyway.
    return undefined
  }
}

// The first page load is a visit too -- it just wasn't routed by Inertia, so
// the component name comes off the root element's serialized page object.
function initialVisit(): Visit | null {
  const nav = navigationEntry()
  if (!nav) return null

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

export function startLantern(options: LanternOptions = {}) {
  ignoreErrors = [ ...DEFAULT_IGNORE_ERRORS, ...(options.ignoreErrors ?? []) ]
  denyUrls = [ ...DEFAULT_DENY_URLS, ...(options.denyUrls ?? []) ]
  tenantOf = options.tenant
  startVitals()
  startSession()
  component = pageComponent()
  initial = initialVisit()
  startBreadcrumbs()
  startErrorCapture()

  router.on("start", (event) => {
    const v = event.detail.visit
    current = {
      started_at: Date.now(),
      url: v.url.toString(),
      method: v.method,
      partial: Boolean(v.only?.length || v.except?.length),
      only: v.only,
    }
    crumb("navigate", `${v.method.toUpperCase()} ${current.url}`)
  })
  router.on("success", (event) => {
    component = event.detail.page.component
    if (!current) return
    current.component = component
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
