// Railwatch browser client for Inertia. Reports each visit's duration,
// component, and prop payload size to /railwatch/beacon so the platform can
// show real page-load timing, plus Core Web Vitals (LCP, CLS, INP, TTFB,
// with TTFB split into redirect / connection / server time) for the
// initial page load, plus every JavaScript error the page throws
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
  // TTFB split into phases (initial load only; see ttfbPhases).
  redirect_ms?: number
  redirect_count?: number
  connect_ms?: number
  server_ms?: number
  // The browser session and the tab the visit happened in, for the journey.
  session_id?: string
  tab_id?: string
}

// The browser's session, for release health and the session journey, on the
// wire. `ended` only when this tab has seen it time out (see `begin`).
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
  // The session and tab it was thrown in, taken when it was: another tab
  // may move the session on before this one flushes.
  session_id?: string
  tab_id?: string
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

export interface RailwatchOptions {
  // Messages that are never worth an issue, added to the defaults below. A
  // string matches anywhere in the message; a regex is tested against it.
  ignoreErrors?: (string | RegExp)[]
  // Scripts whose failures are not this app's to fix, added to the defaults
  // below and matched against the top stack frame's URL.
  denyUrls?: RegExp[]
  // The tenant the user is looking at. The beacon posts to /railwatch/beacon,
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
const DEFAULT_DENY_URLS = [
  /extensions\//i,
  /^chrome:\/\//i,
  /^moz-extension:\/\//i,
]

const SESSION_ID_KEY = "railwatch.session"
const SESSION_SEEN_KEY = "railwatch.session.seen"
const SESSION_STARTED_KEY = "railwatch.session.at"
const TAB_KEY = "railwatch.tab"
// The GA4/Amplitude rules: a session is over after 30 minutes with no
// activity in any tab (config.session_timeout's default, which the server
// half times out on too), and after 24 hours whatever happens.
const SESSION_TIMEOUT_MS = 30 * 60 * 1000
const SESSION_CAP_MS = 24 * 60 * 60 * 1000
// Railwatch::Sessions reads these, ahead of the cookie.
const SESSION_HEADER = "X-Railwatch-Session"
const TAB_HEADER = "X-Railwatch-Tab"

const queue: Visit[] = []
const errors: JsError[] = []
const crumbs: Crumb[] = []
let current: Visit | null = null
let initial: Visit | null = null
// `seen` is the session's last activity in any tab, as far as this one knows.
let session: { id: string; started_at: number; seen: number } | null = null
let tab = ""
// The Inertia page component the user is on, so an error that fires between
// visits still says which screen it broke.
let component: string | undefined
let finalized = false
let timer: number | undefined
let ignoreErrors: (string | RegExp)[] = DEFAULT_IGNORE_ERRORS
let denyUrls: RegExp[] = DEFAULT_DENY_URLS
let tenantOf: (() => string | undefined) | undefined
// Whether the user is waiting on a request. A visit the page starts by
// itself -- a poll, a refresh when the tab comes back, a prefetch on hover
// -- runs without the progress bar (`showProgress: false`, which Inertia
// derives from `async: true`), and when one drops its connection nothing
// the user did has failed: the page keeps what it has and the next tick
// refreshes it. A laptop waking on a new network used to open an issue
// that way. So a dropped request is reported only while the user is
// waiting, which is one of two things. `foregroundVisits` counts visits
// with the progress bar (or a deferred-props load, which the user watches
// as a skeleton) between `start` and `finish`. `foregroundRequest` is a
// visit the user asked for that has no request of its own: Inertia serves
// a click from a prefetch already in the air without ever firing `start`
// for it, so `before` is the one event it gets, and it stands until that
// visit lands (`success`/`error` naming its id), a waiting request starts,
// its drop is reported, or a `before` listener cancels it. Not `navigate`:
// an instant visit fires that for its placeholder before the prefetch is
// even looked up. Counted and flagged rather than matched, because the
// failure event names only the error, not the visit. An app that wants a
// particular background refresh reported passes `showProgress: true`.
let foregroundVisits = 0
let foregroundRequest: { id?: string } | null = null
// Errors Inertia has already delivered through its own failure event. It
// re-rejects the same object afterwards and nothing awaits it, so the error
// arrives a second time as an unhandled rejection; that copy is dropped
// whether or not the first was reported.
const requestFailures = new WeakSet<object>()

// The engine's beacon, under the dashboard's mount point when the page has
// one (<meta name="railwatch-mount">, lib/mount.ts; inlined because this
// file is copied into apps on its own). An app's own pages have no such tag
// and post to the engine at its default mount.
function endpoint() {
  const mount =
    document
      .querySelector<HTMLMetaElement>('meta[name="railwatch-mount"]')
      ?.content.trim()
      .replace(/\/+$/, "") ?? ""
  return /^\/(?![/\\])/.test(mount) ? `${mount}/beacon` : "/railwatch/beacon"
}

function csrf() {
  return (
    document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
      ?.content ?? ""
  )
}

function post(payload: {
  visits: Visit[]
  errors: JsError[]
  session?: Session
  tenant?: string
}) {
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

function flush(force = false) {
  if (queue.length === 0 && errors.length === 0 && !force) return
  touch(false)
  post({
    visits: queue.splice(0, queue.length),
    errors: errors.splice(0, errors.length),
    session: beat(),
    tenant: tenant(),
  })
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

interface Store {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

// Where the session lives: localStorage, so every tab of the browser shares
// one; sessionStorage when localStorage throws (storage disabled, a
// sandboxed frame), which narrows the session to the tab; memory when both
// throw, which narrows it to the page. The tab id lives in sessionStorage,
// which survives a reload of the tab and nothing else, or in memory.
let sessions: Store = memoryStore()
let tabs: Store = memoryStore()

function storage(kind: "localStorage" | "sessionStorage"): Store | undefined {
  try {
    const store = window[kind]
    store.setItem("railwatch.probe", "1")
    store.removeItem("railwatch.probe")
    return store
  } catch {
    // Disabled, or denied to this frame. The caller tries the next one.
    return undefined
  }
}

function memoryStore(): Store {
  const values = new Map<string, string>()
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => void values.set(key, value),
  }
}

// A full store throws on write. The session then lasts as long as this
// page's memory of it, which is all a write could have bought.
function save(store: Store, key: string, value: string) {
  try {
    store.setItem(key, value)
  } catch {
    // Quota exceeded.
  }
}

// Mirrors the id into a cookie so every request the browser makes carries
// it, full page loads included -- that is what lets the server side of the
// session (Railwatch::Sessions) join the browser side under one id. It
// lapses with the session's idle timeout, so the first page load after one
// does not carry the dead id; every activity in any tab renews it.
function remember(id: string) {
  try {
    // Railwatch::Sessions::COOKIE reads this name to stitch server requests to the browser session.
    document.cookie = `railwatch_session=${id}; path=/; max-age=${SESSION_TIMEOUT_MS / 1000}; SameSite=Lax`
  } catch {
    // A sandboxed frame has no cookies. Visits still carry the headers.
  }
}

// A store that passed the probe can still throw later: the user turns
// storage off, or the browser revokes it. From then on the page keeps its
// own copy, seeded with the session it is in, so losing storage neither
// stops the client nor ends the session.
function read(key: string): string | null {
  try {
    return sessions.getItem(key)
  } catch {
    sessions = memoryStore()
    if (session) {
      sessions.setItem(SESSION_ID_KEY, session.id)
      sessions.setItem(SESSION_STARTED_KEY, String(session.started_at))
      sessions.setItem(SESSION_SEEN_KEY, String(session.seen))
    }
    return sessions.getItem(key)
  }
}

function readTab(): string | null {
  try {
    return tabs.getItem(TAB_KEY)
  } catch {
    tabs = memoryStore()
    return null
  }
}

function startSession() {
  sessions =
    storage("localStorage") ?? storage("sessionStorage") ?? memoryStore()
  tabs = storage("sessionStorage") ?? memoryStore()
  tab = readTab() ?? randomId()
  save(tabs, TAB_KEY, tab)
  touch(true)
}

// Brings this tab's session up to date with the browser's, joining the one
// another tab opened meanwhile. `active` is the user doing something -- the
// page loading, a visit they wait on, the tab coming back into view -- which
// keeps the session alive, or opens a new one when the last went 30 minutes
// without activity in any tab or is 24 hours old. Anything else (a
// background poll, a prefetch, a flush) only joins a live session, so a tab
// left polling cannot hold its session open until the cap.
function touch(active: boolean) {
  const now = Date.now()
  const id = read(SESSION_ID_KEY)
  const seen = Number(read(SESSION_SEEN_KEY)) || 0
  const startedAt = Number(read(SESSION_STARTED_KEY)) || 0
  const live = id !== null && !expired(startedAt, seen, now)
  if (live && id === session?.id) session.seen = Math.max(session.seen, seen)
  else if (live) begin(id, startedAt, seen, false)
  else if (active) begin(minted(id) ?? randomId(), now, now, true)
  if (!active || !session) return
  session.seen = now
  save(sessions, SESSION_SEEN_KEY, String(now))
  remember(session.id)
}

// The id the server put in the cookie for this browser's first page load
// (Railwatch::Sessions.mint), so the session starts with that request rather
// than after it. Not the session that just expired, whose id the cookie
// can still hold.
function minted(expiredId: string | null): string | undefined {
  try {
    const id = /(?:^|;\s*)railwatch_session=([A-Za-z0-9_-]{1,64})(?:;|$)/.exec(
      document.cookie,
    )?.[1]
    return id && id !== expiredId && id !== session?.id ? id : undefined
  } catch {
    // A sandboxed frame has no cookies.
    return undefined
  }
}

function expired(startedAt: number, seen: number, now: number) {
  return now - seen >= SESSION_TIMEOUT_MS || now - startedAt >= SESSION_CAP_MS
}

// The session this tab is in, while it is live. A background visit after it
// timed out belongs to no session: it is neither tagged nor recorded as one.
function liveSession(): string | undefined {
  if (!session || expired(session.started_at, session.seen, Date.now()))
    return undefined
  return session.id
}

// Moves this tab into a session. The one it was in is over -- a session is
// only replaced once it has timed out or reached the cap -- so this tab
// says so with a last, `ended` beat. Closing a tab sends no such thing: the
// browser's other tabs may still be in the session, and nothing a closing
// tab knows says otherwise. A session no tab comes back to ends where the
// server half's does, on its own timeout.
function begin(id: string, startedAt: number, seen: number, minted: boolean) {
  if (session)
    post({
      visits: [],
      errors: [],
      session: {
        id: session.id,
        started_at: session.started_at,
        duration_ms: session.seen - session.started_at,
        ended: true,
      },
      tenant: tenant(),
    })
  session = { id, started_at: startedAt, seen }
  if (!minted) return
  save(sessions, SESSION_ID_KEY, id)
  save(sessions, SESSION_STARTED_KEY, String(startedAt))
  save(sessions, SESSION_SEEN_KEY, String(seen))
  // No duration on the first beat: that is what opens the session.
  post({
    visits: [],
    errors: [],
    session: { id, started_at: startedAt },
    tenant: tenant(),
  })
}

// While the session is live it runs to now, whichever tab is beating it. One
// this tab has watched time out ran to its last activity, and is `ended`.
function beat(): Session | undefined {
  if (!session) return undefined
  const now = Date.now()
  const ended = expired(session.started_at, session.seen, now)
  return {
    id: session.id,
    started_at: session.started_at,
    duration_ms: (ended ? session.seen : now) - session.started_at,
    ended,
  }
}

// Inertia sends a visit with whatever headers the visit object holds once
// `before` has fired, so setting them here tags every visit, prefetch, poll
// and partial reload with the session and the tab -- which is how a request
// record joins its journey under the tab it came from. Only for the page's
// own origin: a custom header makes a cross-origin request preflight, and
// another origin is not this app's server anyway. The headers object is
// replaced, not written into, because it may be the app's own options. The
// prefetch cache compares headers; a prefetch and the click it serves are
// tagged alike, so the prefetch still serves.
function tag(visit: { url: unknown; headers?: Record<string, string> }) {
  const id = liveSession()
  if (!id) return
  try {
    if (new URL(String(visit.url), location.href).origin !== location.origin)
      return
  } catch {
    // Not a URL Inertia could visit either.
    return
  }
  visit.headers = {
    ...visit.headers,
    [SESSION_HEADER]: id,
    [TAB_HEADER]: tab,
  }
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
  while (taken.length > 0 && JSON.stringify(taken).length > MAX_CRUMB_BYTES)
    taken.shift()
  return taken
}

// "button#save.btn.primary "Save order"" -- enough to recognise what was
// clicked, and never an input's value, which is the user's data and not
// ours to ship.
function describeTarget(target: EventTarget | null): string {
  if (!(target instanceof Element)) return ""
  const id = target.id ? `#${target.id}` : ""
  const className =
    typeof target.className === "string" ? target.className.trim() : ""
  const classes = className ? `.${className.split(/\s+/).join(".")}` : ""
  const text =
    target instanceof HTMLInputElement
      ? ""
      : (target.textContent ?? "").trim().replace(/\s+/g, " ").slice(0, 80)
  return `${target.tagName.toLowerCase()}${id}${classes}${text ? ` "${text}"` : ""}`
}

function startBreadcrumbs() {
  document.addEventListener(
    "click",
    (event) => crumb("click", describeTarget(event.target)),
    true,
  )
  for (const level of ["error", "warn"] as const) {
    const original = console[level].bind(console) as (
      ...args: unknown[]
    ) => void
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
  if (
    ignoreErrors.some((pattern) =>
      typeof pattern === "string"
        ? message.includes(pattern)
        : pattern.test(message),
    )
  )
    return true
  const url = stack ? topFrameUrl(stack) : undefined
  if (!url) return false
  if (denyUrls.some((pattern) => pattern.test(url))) return true
  return !url.startsWith("/") && !url.startsWith(`${location.origin}/`)
}

function capture(
  name: string,
  message: string,
  stack?: string,
  context?: Record<string, unknown>,
) {
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
    session_id: liveSession(),
    tab_id: tab,
    breadcrumbs: breadcrumbs.length > 0 ? breadcrumbs : undefined,
    context,
  }
  // Deduped within the flush, not across the page's life: a render loop
  // throws the same error every retry. (Inertia's re-rejection of a failed
  // request is dropped by identity in the rejection handler instead.)
  if (
    errors.some(
      (e) =>
        e.name === error.name &&
        e.message === error.message &&
        e.stack === error.stack,
    )
  )
    return
  errors.push(error)
}

// Anything at all can be thrown or rejected in JavaScript, not just an
// Error. A non-Error value is reported under `fallback` with whatever it
// stringifies to as the message.
function captureValue(
  value: unknown,
  fallback: string,
  context?: Record<string, unknown>,
) {
  if (value instanceof Error)
    capture(value.name, value.message, value.stack, context)
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

// React 19's root error options, for `createRoot(el, railwatchRootOptions())`.
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

export function railwatchRootOptions(): {
  onCaughtError: (error: unknown, info: ReactErrorInfo) => void
  onUncaughtError: (error: unknown, info: ReactErrorInfo) => void
} {
  const report = (error: unknown, info: ReactErrorInfo) =>
    captureValue(
      error,
      "Error",
      info.componentStack ? { componentStack: info.componentStack } : undefined,
    )
  return { onCaughtError: report, onUncaughtError: report }
}

// What a console argument or a rejected value reads as in a breadcrumb or
// an error message. A plain object or array is shown as JSON (capped) rather
// than "[object Object]"; an Error keeps its own message.
function stringify(value: unknown) {
  try {
    if (value instanceof Error) return `${value.name}: ${value.message}`
    if (
      Array.isArray(value) ||
      (typeof value === "object" &&
        value !== null &&
        value.toString === Object.prototype.toString)
    ) {
      return JSON.stringify(value).slice(0, MAX_CRUMB_TEXT)
    }
    return String(value)
  } catch {
    // A Symbol, a cyclic object, or an object whose toString throws.
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
// only knows its own version's names. The first kind is reported only for
// a visit the user is waiting on -- see `foregroundVisits`.
function startErrorCapture() {
  window.addEventListener("error", (event) => {
    // Neither an error object nor a message means there is nothing to
    // report -- a failed <img> or <script> load, not a JavaScript error.
    if (!event.error && !event.message) return
    captureValue((event.error ?? event.message) as unknown, "Error")
  })
  window.addEventListener("unhandledrejection", (event) => {
    const reason = event.reason as unknown
    if (
      typeof reason === "object" &&
      reason !== null &&
      requestFailures.has(reason)
    )
      return
    captureValue(reason, "UnhandledRejection")
  })
  onInertia("exception", (detail) => captureRequestFailure(detail.exception))
  onInertia("networkError", (detail) => captureRequestFailure(detail.error))
  onInertia("invalid", (detail) => captureInvalidResponse(detail.response))
  onInertia("httpException", (detail) =>
    captureInvalidResponse(detail.response),
  )
}

// A visit the user is waiting on: one that shows the progress bar, or the
// load of a page's deferred props, which Inertia starts by itself but the
// user watches as a skeleton. Read structurally so the same file compiles
// against Inertia 2 and 3, whose visit types differ.
function waiting(visit: object): boolean {
  return (
    ("showProgress" in visit && visit.showProgress === true) ||
    ("deferredProps" in visit && visit.deferredProps === true)
  )
}

// Inertia 3 stamps every visit with an id and names it on `success` and
// `error`. Inertia 2 has neither, so there a landing cannot be told apart
// from a background poll's and clears nothing: the request stands until
// the next waiting `before`, a waiting `start`, or a reported failure,
// which can only over-report.
function idOf(record: object, key: string): string | undefined {
  const value =
    key in record ? (record as Record<string, unknown>)[key] : undefined
  return typeof value === "string" ? value : undefined
}

function landed(detail: object) {
  if (
    foregroundRequest?.id !== undefined &&
    idOf(detail, "visitId") === foregroundRequest.id
  ) {
    foregroundRequest = null
  }
}

// The failure fires before the visit's `finish`, so the visit that failed
// is still counted: nothing counted and nothing requested means only
// background visits were in the air, and one of those is what dropped. A
// requested visit whose request dropped is over; the next thing the user
// does is a new `before`.
function captureRequestFailure(error: unknown) {
  if (typeof error === "object" && error !== null) requestFailures.add(error)
  if (foregroundVisits === 0 && !foregroundRequest) return
  foregroundRequest = null
  captureValue(error, "InertiaException")
}

function onInertia(
  name: string,
  handler: (detail: Record<string, unknown>) => void,
) {
  document.addEventListener(`inertia:${name}`, (event) => {
    const detail = (event as CustomEvent<unknown>).detail
    handler(
      typeof detail === "object" && detail !== null
        ? (detail as Record<string, unknown>)
        : {},
    )
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
  const res = (response ?? {}) as {
    status?: unknown
    headers?: Record<string, unknown>
  }
  if (inertiaResponse(res.headers)) return
  const status = typeof res.status === "number" ? res.status : "unknown status"
  const contentType = res.headers?.["content-type"]
  capture(
    "InertiaInvalidResponse",
    `Inertia invalid response (${status})`,
    undefined,
    {
      status,
      ...(typeof contentType === "string" ? { content_type: contentType } : {}),
    },
  )
}

function inertiaResponse(
  headers: Record<string, unknown> | undefined,
): boolean {
  if (!headers || typeof headers !== "object") return false
  return Object.keys(headers).some(
    (key) => key.toLowerCase() === "x-inertia" && headers[key],
  )
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

function observe(
  type: string,
  callback: (entries: VitalEntry[]) => void,
  options: ObserveOptions = {},
) {
  if (typeof PerformanceObserver === "undefined") return
  try {
    const observer = new PerformanceObserver((list) =>
      callback(list.getEntries()),
    )
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
  const entries: PerformanceEntry[] =
    performance.getEntriesByType?.("navigation") ?? []
  const nav = entries[0]
  return nav?.entryType === "navigation"
    ? (nav as PerformanceNavigationTiming)
    : undefined
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
      if (
        sessionValue &&
        entry.startTime - sessionLast < 1000 &&
        entry.startTime - sessionFirst < 5000
      ) {
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

// The component the server rendered this page with, off the serialized page
// object: inertia_rails 3.23+ renders it as <script data-page="app"
// type="application/json">, older ones as <div id="app" data-page="...">.
// Inertia's own events take over from here.
function pageComponent(): string | undefined {
  try {
    const script = document.querySelector(
      'script[data-page="app"][type="application/json"]',
    )
    const raw = script
      ? script.textContent
      : document.getElementById("app")?.dataset.page
    const page = JSON.parse(raw ?? "{}") as { component?: string }
    return page.component
  } catch {
    // Not an Inertia-rendered page, or the payload moved. Report it anyway.
    return undefined
  }
}

// Where the initial load's TTFB went, in three phases that add up to it:
//
//   redirect_ms  navigation start -> the final request's start: every
//                redirect hop, plus the browser's own few ms (so never
//                quite 0).
//   connect_ms   -> requestStart: service worker startup, HTTP cache, DNS,
//                TCP and TLS for the final request.
//   server_ms    -> responseStart: the network round trip and the server's
//                time.
//
// The final request starts at fetchStart, or at workerStart when a service
// worker had to start first (the web-vitals library cuts there too).
//
// redirect_ms stays honest when a hop is cross-origin. The browser then
// zeroes redirectCount, redirectStart and redirectEnd (Navigation Timing 2),
// but fetchStart is still the final request's start (Fetch's "post-redirect
// start time"), so the hidden hops' time is still in it.
//
// redirect_count is sent only when the browser shows the redirects. A 0
// means "no redirect" or "hidden", and a hidden redirect must never be
// reported as no redirect.
//
// The boundaries are rounded before subtracting, so the three phases add up
// to the reported ttfb exactly. A browser whose timestamps are missing or
// out of order sends no phases rather than a wrong split.
function ttfbPhases(nav: PerformanceNavigationTiming): Partial<Visit> {
  const fetchStart =
    nav.workerStart > 0 && nav.workerStart < nav.fetchStart
      ? nav.workerStart
      : nav.fetchStart
  // Order is judged on the raw timestamps: rounding first would let a
  // requestStart a hair before fetchStart through as a 0 ms phase.
  const ordered =
    nav.responseStart > 0 &&
    fetchStart >= nav.startTime &&
    nav.requestStart >= fetchStart &&
    nav.responseStart >= nav.requestStart
  if (!ordered) return {}
  const [start, fetched, requested, responded] = [
    nav.startTime,
    fetchStart,
    nav.requestStart,
    nav.responseStart,
  ].map(Math.round)
  return {
    redirect_ms: fetched - start,
    redirect_count: nav.redirectCount > 0 ? nav.redirectCount : undefined,
    connect_ms: requested - fetched,
    server_ms: responded - requested,
  }
}

// The first page load is a visit too -- it just wasn't routed by Inertia, so
// the component name comes off the root element's serialized page object.
function initialVisit(): Visit | null {
  const nav = navigationEntry()
  if (!nav) return null

  const duration = (nav.loadEventEnd || nav.responseEnd) - nav.startTime
  return {
    started_at: Math.round(
      (performance.timeOrigin ?? Date.now() - performance.now()) +
        nav.startTime,
    ),
    url: location.pathname + location.search,
    method: "GET",
    component,
    duration_ms: duration,
    status: "success",
    ...ttfbPhases(nav),
    session_id: liveSession(),
    tab_id: tab,
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
  // session beat, which the platform dedupes by session id.
  flush(true)
}

export function startRailwatch(options: RailwatchOptions = {}) {
  ignoreErrors = [...DEFAULT_IGNORE_ERRORS, ...(options.ignoreErrors ?? [])]
  denyUrls = [...DEFAULT_DENY_URLS, ...(options.denyUrls ?? [])]
  tenantOf = options.tenant
  startVitals()
  startSession()
  component = pageComponent()
  initial = initialVisit()
  startBreadcrumbs()
  startErrorCapture()

  // `before` fires for a click before Inertia looks for a prefetch to serve
  // it with, so it is the one event a prefetch-served visit has of its own.
  // A prefetch's own `before` carries no progress bar and is not counted.
  // Listeners registered after this one may still cancel the visit (an
  // unsaved-changes guard, say), and a cancelled visit fires nothing more;
  // the dispatch is over by the time the microtask runs, so the answer is
  // final there.
  router.on("before", (event) => {
    const v = event.detail.visit
    if (event.defaultPrevented) return
    touch(waiting(v))
    tag(v)
    if (!waiting(v)) return
    const request = (foregroundRequest = { id: idOf(v, "id") })
    queueMicrotask(() => {
      if (event.defaultPrevented && foregroundRequest === request)
        foregroundRequest = null
    })
  })
  router.on("start", (event) => {
    const v = event.detail.visit
    if (waiting(v)) {
      foregroundVisits++
      foregroundRequest = null
    }
    current = {
      started_at: Date.now(),
      url: v.url.toString(),
      method: v.method,
      partial: Boolean(v.only?.length || v.except?.length),
      only: v.only,
      session_id: liveSession(),
      tab_id: tab,
    }
    crumb("navigate", `${v.method.toUpperCase()} ${current.url}`)
  })
  router.on("success", (event) => {
    landed(event.detail)
    component = event.detail.page.component
    if (!current) return
    current.component = component
    current.props_bytes = JSON.stringify(event.detail.page.props ?? {}).length
    current.status = "success"
  })
  router.on("error", (event) => {
    landed(event.detail)
    if (current) current.status = "error"
  })
  router.on("finish", (event) => {
    // Fires once whether the visit completed, failed, or was cancelled.
    // Clamped so a missed start can only over-report, never silence.
    if (waiting(event.detail.visit))
      foregroundVisits = Math.max(0, foregroundVisits - 1)
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
    else touch(true)
  })
  window.addEventListener("pagehide", finalize)
}
