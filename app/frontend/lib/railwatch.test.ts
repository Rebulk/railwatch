import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import type { RailwatchOptions } from "@/lib/railwatch"

interface EventDetail {
  visit?: {
    url: string
    method: string
    only?: string[]
    except?: string[]
    showProgress?: boolean
  }
  page?: { component: string; props: Record<string, unknown> }
  exception?: Error
  response?: { status: number }
}

type Handler = (event: { detail: EventDetail }) => void

let handlers: Record<string, Handler[]>
const on = vi.fn((event: string, handler: Handler) => {
  ;(handlers[event] ??= []).push(handler)
  return () => undefined
})

vi.mock("@inertiajs/react", () => ({
  router: { on },
}))

function fire(event: string, detail: EventDetail) {
  for (const handler of handlers[event] ?? []) handler({ detail })
}

// jsdom's Blob doesn't implement .text()/.arrayBuffer(), and reading one via
// FileReader deadlocks under fake timers (its completion is itself
// scheduled through a faked timer that nothing here advances). Stub the
// global Blob constructor with a double that keeps its parts accessible
// synchronously instead.
class FakeBlob {
  parts: BlobPart[]
  type: string
  constructor(parts: BlobPart[], options?: BlobPropertyBag) {
    this.parts = parts
    this.type = options?.type ?? ""
  }
}

interface Body {
  visits: Record<string, unknown>[]
  errors: Record<string, unknown>[]
  tenant?: string
}

function blobBody(blob: unknown): Body {
  return JSON.parse((blob as FakeBlob).parts[0] as string) as Body
}

// Simulates one full Inertia visit lifecycle: start -> (success | error) ->
// finish, matching the sequence Inertia actually fires. Every event carries
// the visit, as Inertia's do; a plain click shows the progress bar.
function completeVisit(url: string, outcome: "success" | "error" = "success") {
  const visit = { url, method: "get", showProgress: true }
  fire("start", { visit })
  if (outcome === "success") {
    fire("success", { page: { component: "Dashboard", props: { a: 1 } } })
  } else {
    fire("error", {})
  }
  fire("finish", { visit })
}

let sendBeacon: ReturnType<typeof vi.fn>
let fetchMock: ReturnType<typeof vi.fn>
let start: (options?: RailwatchOptions) => void
let report: (error: unknown, context?: Record<string, unknown>) => void
let rootOptions: () => {
  onCaughtError: (
    error: unknown,
    info: { componentStack?: string | null },
  ) => void
  onUncaughtError: (
    error: unknown,
    info: { componentStack?: string | null },
  ) => void
}

// startRailwatch() registers window "pagehide", "error", and
// "unhandledrejection" listeners that live for as long as their module
// instance does. Since each test imports a fresh module instance (via
// resetModules) but they all share the same jsdom window, intercept
// window.addEventListener to capture this test's own listeners so they — and
// only they — can be invoked and torn down, rather than accumulating stale
// listeners from earlier tests' module instances on a real dispatch.
const originalAddEventListener = window.addEventListener.bind(window)
let listeners: Record<string, EventListener>
// The same for the "inertia:<name>" listeners the client registers on
// document: an earlier test's module instance may still be mid-visit, and a
// real dispatch would have it report the failure through this test's mocks.
const originalDocumentAddEventListener =
  document.addEventListener.bind(document)
let documentListeners: Record<string, EventListener>

beforeEach(async () => {
  vi.resetModules()
  vi.useFakeTimers()
  vi.setSystemTime(new Date("2026-09-03T12:00:00.000Z"))
  handlers = {}
  on.mockClear()

  sendBeacon = vi.fn(() => true)
  Object.defineProperty(navigator, "sendBeacon", {
    value: sendBeacon,
    configurable: true,
  })
  fetchMock = vi.fn(() => Promise.resolve(new Response(null, { status: 200 })))
  vi.stubGlobal("fetch", fetchMock)
  vi.stubGlobal("Blob", FakeBlob)

  document.head.innerHTML = '<meta name="csrf-token" content="tok123">'

  listeners = {}
  window.addEventListener = ((
    type: string,
    listener: EventListenerOrEventListenerObject,
    options?: boolean | AddEventListenerOptions,
  ) => {
    listeners[type] = listener as EventListener
    originalAddEventListener(type, listener, options)
  }) as typeof window.addEventListener

  documentListeners = {}
  document.addEventListener = ((
    type: string,
    listener: EventListenerOrEventListenerObject,
    options?: boolean | AddEventListenerOptions,
  ) => {
    documentListeners[type] = listener as EventListener
    originalDocumentAddEventListener(type, listener, options)
  }) as typeof document.addEventListener

  const module = await import("@/lib/railwatch")
  start = module.startRailwatch
  report = module.reportError
  rootOptions = module.railwatchRootOptions
  start()
})

afterEach(() => {
  window.addEventListener = originalAddEventListener
  document.addEventListener = originalDocumentAddEventListener
  vi.useRealTimers()
  vi.unstubAllGlobals()
  document.head.innerHTML = ""
})

function listenerFor(type: string): EventListener {
  const listener = listeners[type]
  if (!listener) throw new Error(`no ${type} listener registered`)
  return listener
}

function currentPagehideListener(): EventListener {
  return listenerFor("pagehide")
}

// jsdom has no PromiseRejectionEvent constructor and building a real
// ErrorEvent adds nothing here, so each handler is handed the one or two
// properties the client actually reads off its event.
function throwUncaught(error: unknown, message = "") {
  listenerFor("error")({ error, message } as unknown as Event)
}

function rejectUnhandled(reason: unknown) {
  listenerFor("unhandledrejection")({ reason } as unknown as Event)
}

function lastFlush() {
  const calls = sendBeacon.mock.calls
  const [, blob] = calls[calls.length - 1] as [string, FakeBlob]
  return blobBody(blob)
}

// Every error shipped so far, across every flush. Nothing queued means no
// flush at all, so "no errors were reported" cannot be read off a last one.
function allErrors() {
  return sendBeacon.mock.calls.flatMap(([, blob]) => blobBody(blob).errors)
}

// A stack pointing at a script on the origin jsdom serves this suite from,
// so an error built with it counts as the app's own code.
function ownStack(file = "/assets/index-Bq1.js") {
  return `Error: boom\n    at IssueRow (${file}:41:2210)`
}

describe("startRailwatch batching", () => {
  // Starting the client opens the tab's session with one visit-less beacon
  // (release health needs the session to exist before its first beat), so
  // "nothing flushed yet" means exactly that one call and no visits in it.
  it("does not flush a queued visit before the 5s timer or the 20-visit threshold", () => {
    completeVisit("/dashboard")
    expect(sendBeacon).toHaveBeenCalledTimes(1)
    expect(blobBody(sendBeacon.mock.calls[0][1]).visits).toEqual([])
  })

  it("flushes automatically once the 5s timer elapses", () => {
    completeVisit("/dashboard")
    vi.advanceTimersByTime(5000)
    expect(sendBeacon).toHaveBeenCalledTimes(1)
  })

  it("flushes as soon as the queue reaches 20 visits, without waiting for the timer", () => {
    for (let i = 0; i < 20; i++) completeVisit(`/page-${i}`)
    expect(sendBeacon).toHaveBeenCalledTimes(1)
  })

  it("flushes on the pagehide event", () => {
    completeVisit("/dashboard")
    currentPagehideListener()(new Event("pagehide"))
    expect(sendBeacon).toHaveBeenCalledTimes(1)
  })

  it("batches multiple queued visits into a single sendBeacon call to /railwatch/beacon", () => {
    completeVisit("/a")
    completeVisit("/b")
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).toHaveBeenCalledTimes(1)
    const [url, blob] = sendBeacon.mock.calls[0] as [string, FakeBlob]
    expect(url).toBe("/railwatch/beacon")
    expect(blobBody(blob).visits.map((v) => v.url)).toEqual(["/a", "/b"])
  })

  it("does not send an empty batch when the timer fires with nothing queued", () => {
    vi.advanceTimersByTime(5000)
    expect(sendBeacon).not.toHaveBeenCalled()
  })
})

describe("startRailwatch visit status", () => {
  it("marks a visit that fires the success event as status success", () => {
    completeVisit("/dashboard", "success")
    vi.advanceTimersByTime(5000)

    const blob = sendBeacon.mock.calls[0][1] as FakeBlob
    expect(blobBody(blob).visits[0].status).toBe("success")
  })

  it("marks a visit that fires the error event as status error", () => {
    completeVisit("/dashboard", "error")
    vi.advanceTimersByTime(5000)

    const blob = sendBeacon.mock.calls[0][1] as FakeBlob
    expect(blobBody(blob).visits[0].status).toBe("error")
  })

  it("marks a visit that finishes without a success or error event as cancelled", () => {
    fire("start", { visit: { url: "/dashboard", method: "get" } })
    fire("finish", { visit: { url: "/dashboard", method: "get" } })
    vi.advanceTimersByTime(5000)

    const blob = sendBeacon.mock.calls[0][1] as FakeBlob
    expect(blobBody(blob).visits[0].status).toBe("cancelled")
  })

  it("records duration_ms as the elapsed time between start and finish", () => {
    fire("start", { visit: { url: "/dashboard", method: "get" } })
    vi.setSystemTime(new Date("2026-09-03T12:00:00.250Z"))
    fire("success", { page: { component: "Dashboard", props: {} } })
    fire("finish", { visit: { url: "/dashboard", method: "get" } })
    vi.advanceTimersByTime(5000)

    const blob = sendBeacon.mock.calls[0][1] as FakeBlob
    expect(blobBody(blob).visits[0].duration_ms).toBe(250)
  })
})

describe("startRailwatch fetch fallback", () => {
  it("falls back to fetch with the CSRF token header when sendBeacon is unavailable", () => {
    Object.defineProperty(navigator, "sendBeacon", {
      value: undefined,
      configurable: true,
    })

    completeVisit("/dashboard")
    vi.advanceTimersByTime(5000)

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe("/railwatch/beacon")
    expect((init.headers as Record<string, string>)["X-CSRF-Token"]).toBe(
      "tok123",
    )
    expect(init.keepalive).toBe(true)
  })

  it("sends an empty CSRF header when no csrf-token meta tag is present", () => {
    document.head.innerHTML = ""
    Object.defineProperty(navigator, "sendBeacon", {
      value: undefined,
      configurable: true,
    })

    completeVisit("/dashboard")
    vi.advanceTimersByTime(5000)

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect((init.headers as Record<string, string>)["X-CSRF-Token"]).toBe("")
  })
})

describe("startRailwatch error capture", () => {
  it("reports an uncaught error with its name, message, and raw stack", () => {
    const error = new Error("kaboom")
    error.stack =
      "Error: kaboom\n    at IssueRow (/assets/index-Bq1.js:41:2210)"
    const thrownAt = Date.now()
    throwUncaught(error)
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors).toEqual([
      {
        at: thrownAt,
        name: "Error",
        message: "kaboom",
        stack: error.stack,
        url: "/",
      },
    ])
  })

  it("reports an unhandled promise rejection of an Error under that error's own name", () => {
    rejectUnhandled(new TypeError("undefined is not a function"))
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).toMatchObject({
      name: "TypeError",
      message: "undefined is not a function",
    })
  })

  it("reports a rejection of something that is not an Error under UnhandledRejection", () => {
    rejectUnhandled({ toString: () => "plain object" })
    vi.advanceTimersByTime(5000)

    const [reported] = lastFlush().errors
    expect(reported).toMatchObject({
      name: "UnhandledRejection",
      message: "plain object",
    })
    expect(reported).not.toHaveProperty("stack")
  })

  it("ignores an error event carrying neither an error object nor a message", () => {
    throwUncaught(null)
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })

  // Inertia dispatches every router event as "inertia:<name>" on document;
  // the client listens there because the request-failure events were
  // renamed between Inertia 2 and 3 and the typed router.on knows only one
  // set of names.
  function fireDocument(name: string, detail: unknown) {
    const listener = documentListeners[`inertia:${name}`]
    if (!listener) throw new Error(`no inertia:${name} listener registered`)
    listener({ detail } as unknown as Event)
  }

  // A dropped request is the user's problem only while they are waiting on
  // one: a visit with the progress bar between start and finish.
  function startWaitingVisit(url = "/issues") {
    fire("start", { visit: { url, method: "get", showProgress: true } })
  }

  it("reports the error Inertia 2's exception event carries, which is where a dropped connection lands", () => {
    startWaitingVisit()
    fireDocument("exception", { exception: new Error("Network Error") })
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).toMatchObject({
      name: "Error",
      message: "Network Error",
    })
  })

  it("reports the error Inertia 3's networkError event carries", () => {
    startWaitingVisit()
    fireDocument("networkError", { error: new Error("Network Error") })
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).toMatchObject({
      name: "Error",
      message: "Network Error",
    })
  })

  // A poll, a refresh when the tab comes back, a prefetch on hover: the
  // page started it, nothing the user did has failed, and the next tick
  // refreshes it. A laptop waking on a new network opened LC-16 this way
  // on every deploy.
  it("does not report a dropped request the page started by itself, with no progress bar", () => {
    fire("start", { visit: { url: "/issues", method: "get" } })
    fireDocument("networkError", { error: new Error("Network Error") })
    vi.advanceTimersByTime(5000)

    expect(allErrors()).toEqual([])
  })

  it("does not report a dropped request once the visit the user waited on has finished", () => {
    completeVisit("/issues")
    fireDocument("networkError", { error: new Error("Network Error") })
    vi.advanceTimersByTime(5000)

    expect(allErrors()).toEqual([])
  })

  it("reports a response that was not an Inertia response, with the status it came back with", () => {
    fireDocument("invalid", { response: { status: 403 } })
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).toMatchObject({
      name: "InertiaInvalidResponse",
      message: "Inertia invalid response (403)",
    })
  })

  it("reports Inertia 3's httpException the same way, and survives a detail with no status", () => {
    fireDocument("httpException", {
      response: { status: 502, headers: { "content-type": "text/html" } },
    })
    fireDocument("httpException", undefined)
    vi.advanceTimersByTime(5000)

    const errors = lastFlush().errors
    expect(errors.map((e) => e.message)).toEqual([
      "Inertia invalid response (502)",
      "Inertia invalid response (unknown status)",
    ])
    expect(errors[0].context).toEqual({
      status: 502,
      content_type: "text/html",
    })
  })

  // Inertia 3 fires httpException for a valid Inertia response with a 4xx
  // status too -- a 422 form re-render, a 404 page the app renders on
  // purpose. Those are the app working, not errors.
  it("does not report an Inertia response that merely carries a 4xx status", () => {
    fireDocument("httpException", {
      response: {
        status: 422,
        headers: { "x-inertia": "true", "content-type": "application/json" },
      },
    })
    fireDocument("httpException", {
      response: { status: 404, headers: { "X-Inertia": "true" } },
    })
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })

  it("sends one record for an error thrown repeatedly with the same stack in a single flush", () => {
    const error = new Error("render loop")
    error.stack =
      "Error: render loop\n    at IssueRow (/assets/index-Bq1.js:1:1)"
    for (let i = 0; i < 5; i++) throwUncaught(error)
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors).toHaveLength(1)
  })

  it("keeps two errors whose messages differ apart", () => {
    throwUncaught(new Error("first"))
    throwUncaught(new Error("second"))
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors.map((e) => e.message)).toEqual([
      "first",
      "second",
    ])
  })

  it("tags an error with the Inertia component the user was on", () => {
    completeVisit("/dashboard")
    throwUncaught(new Error("kaboom"))
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0].component).toBe("Dashboard")
  })

  it("tags an error thrown while a visit was in flight with that visit", () => {
    fire("start", { visit: { url: "/issues/7", method: "get" } })
    throwUncaught(new Error("kaboom"))
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0].visit).toBe("/issues/7")
  })

  it("leaves the visit off an error thrown with no visit in flight", () => {
    completeVisit("/dashboard")
    throwUncaught(new Error("kaboom"))
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0].visit).toBeUndefined()
  })

  it("caps a runaway message and stack rather than shipping them whole", () => {
    const error = new Error("x".repeat(5000))
    error.stack = "y".repeat(20000)
    throwUncaught(error)
    vi.advanceTimersByTime(5000)

    const [reported] = lastFlush().errors
    expect((reported.message as string).length).toBe(1000)
    expect((reported.stack as string).length).toBe(8000)
  })

  it("stops queueing after 50 errors in one batch", () => {
    for (let i = 0; i < 60; i++) throwUncaught(new Error(`boom ${i}`))
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors).toHaveLength(50)
  })

  it("flushes errors on the same timer as visits, with no visit of its own", () => {
    throwUncaught(new Error("kaboom"))
    expect(sendBeacon).not.toHaveBeenCalled()

    vi.advanceTimersByTime(5000)
    expect(sendBeacon).toHaveBeenCalledTimes(1)
    expect(lastFlush().visits).toEqual([])
  })

  it("flushes errors on pagehide", () => {
    throwUncaught(new Error("kaboom"))
    currentPagehideListener()(new Event("pagehide"))

    expect(lastFlush().errors).toHaveLength(1)
  })

  it("does not send the same error twice once it has been flushed", () => {
    throwUncaught(new Error("kaboom"))
    vi.advanceTimersByTime(5000)
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).toHaveBeenCalledTimes(1)
  })
})

describe("startRailwatch noise filtering", () => {
  it("drops the two ResizeObserver messages that fire from benign layout thrash", () => {
    throwUncaught(new Error("ResizeObserver loop limit exceeded"))
    throwUncaught(
      new Error("ResizeObserver loop completed with undelivered notifications"),
    )
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })

  it("drops an error thrown by a browser extension", () => {
    const error = new Error("boom")
    error.stack = ownStack("chrome-extension://abcdefg/inject.js")
    throwUncaught(error)
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })

  it("drops an error whose top frame matches a denied url even on the app's own origin", () => {
    const error = new Error("boom")
    error.stack = ownStack("/extensions/injected.js")
    throwUncaught(error)
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })

  it("drops an error thrown by a script on someone else's origin", () => {
    const error = new Error("boom")
    error.stack = ownStack("https://cdn.other.test/widget.js")
    throwUncaught(error)
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })

  it("keeps an error thrown by the app's own code", () => {
    const error = new Error("boom")
    error.stack = ownStack(`${location.origin}/assets/index-Bq1.js`)
    throwUncaught(error)
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors).toHaveLength(1)
  })

  it("keeps an error the browser gave no usable stack for", () => {
    throwUncaught(null, "Script error.")
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0].message).toBe("Script error.")
  })

  it("adds an app's own ignoreErrors to the defaults rather than replacing them", () => {
    start({ ignoreErrors: [/Failed to fetch/] })
    throwUncaught(new Error("Failed to fetch chunk"))
    throwUncaught(new Error("ResizeObserver loop limit exceeded"))
    throwUncaught(new Error("a real bug"))
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors.map((e) => e.message)).toEqual(["a real bug"])
  })

  it("adds an app's own denyUrls to the defaults", () => {
    start({ denyUrls: [/analytics/] })
    const error = new Error("boom")
    error.stack = ownStack("/assets/analytics-tag.js")
    throwUncaught(error)
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })
})

describe("reportError", () => {
  it("reports an error the app caught itself, with the context it passed", () => {
    const error = new Error("LocationPicker failed to load")
    error.stack = ownStack()
    report(error, { componentStack: "\n    at MapErrorBoundary" })
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).toMatchObject({
      name: "Error",
      message: "LocationPicker failed to load",
      context: { componentStack: "\n    at MapErrorBoundary" },
    })
  })

  it("holds a reported error to the same noise filtering as an uncaught one", () => {
    report(new Error("ResizeObserver loop limit exceeded"))
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })
})

describe("startRailwatch breadcrumbs", () => {
  function crumbsOf(): { kind: string; text: string }[] {
    return lastFlush().errors[0].breadcrumbs as { kind: string; text: string }[]
  }

  it("renders a plain object or array in a console crumb as JSON, and a value with its own toString as itself", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => undefined)
    start()
    console.error(
      "payload",
      { status: 404, ok: false },
      [1, 2],
      { toString: () => "custom" },
      new Error("bad"),
    )
    throwUncaught(new Error("after"))
    vi.advanceTimersByTime(5000)

    expect(crumbsOf().slice(-1)[0]).toMatchObject({
      kind: "console",
      text: 'error: payload {"status":404,"ok":false} [1,2] custom Error: bad',
    })
    spy.mockRestore()
  })

  it("records console.error and console.warn as crumbs and still writes them to the console", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => undefined)
    start()
    const loggedAt = Date.now()
    console.error("checkout failed", 42)
    throwUncaught(new Error("boom"))
    vi.advanceTimersByTime(5000)

    expect(crumbsOf()).toEqual([
      { at: loggedAt, kind: "console", text: "error: checkout failed 42" },
    ])
    expect(spy).toHaveBeenCalledWith("checkout failed", 42)
    spy.mockRestore()
  })

  it("records a click as its tag, id, classes, and visible text", () => {
    document.body.innerHTML =
      '<button id="resolve" class="btn primary">Resolve issue</button>'
    document.getElementById("resolve")?.click()
    throwUncaught(new Error("boom"))
    vi.advanceTimersByTime(5000)

    expect(crumbsOf()[0].text).toBe(
      'button#resolve.btn.primary "Resolve issue"',
    )
    document.body.innerHTML = ""
  })

  it("never records what someone typed into an input", () => {
    document.body.innerHTML = '<input id="ssn" value="123-45-6789">'
    document.getElementById("ssn")?.click()
    throwUncaught(new Error("boom"))
    vi.advanceTimersByTime(5000)

    expect(crumbsOf()[0].text).toBe("input#ssn")
    document.body.innerHTML = ""
  })

  it("records each Inertia navigation", () => {
    const visitedAt = Date.now()
    completeVisit("/issues/7")
    throwUncaught(new Error("boom"))
    vi.advanceTimersByTime(5000)

    expect(crumbsOf()).toEqual([
      { at: visitedAt, kind: "navigate", text: "GET /issues/7" },
    ])
  })

  it("keeps only the last twenty crumbs", () => {
    for (let i = 0; i < 30; i++) completeVisit(`/page-${i}`)
    throwUncaught(new Error("boom"))
    vi.advanceTimersByTime(5000)

    const trail = crumbsOf()
    expect(trail).toHaveLength(20)
    expect(trail[19].text).toBe("GET /page-29")
  })

  it("gives up its oldest crumbs rather than blow the byte budget", () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined)
    start()
    for (let i = 0; i < 20; i++) console.warn("x".repeat(600))
    throwUncaught(new Error("boom"))
    vi.advanceTimersByTime(5000)

    const trail = crumbsOf()
    expect(trail.length).toBeLessThan(20)
    expect(JSON.stringify(trail).length).toBeLessThanOrEqual(8000)
    spy.mockRestore()
  })
})

describe("startRailwatch tenant hint", () => {
  it("sends the tenant the app resolves, re-read on every flush", () => {
    let org = "acme"
    start({ tenant: () => org })
    completeVisit("/orgs/acme/orders")
    vi.advanceTimersByTime(5000)
    expect(lastFlush().tenant).toBe("acme")

    org = "globex"
    completeVisit("/orgs/globex/orders")
    vi.advanceTimersByTime(5000)
    expect(lastFlush().tenant).toBe("globex")
  })

  it("sends no tenant when the app configured no resolver", () => {
    completeVisit("/dashboard")
    vi.advanceTimersByTime(5000)

    expect(lastFlush().tenant).toBeUndefined()
  })

  it("still flushes when the app's tenant resolver throws", () => {
    start({
      tenant: () => {
        throw new Error("no page props yet")
      },
    })
    completeVisit("/dashboard")
    vi.advanceTimersByTime(5000)

    expect(lastFlush().visits).toHaveLength(1)
    expect(lastFlush().tenant).toBeUndefined()
  })
})

// React does not hand a boundary-caught error to window.onerror outside a
// development build — React 18 stops at componentDidCatch and React 19 sends
// it to console.error — so these root options are the only thing that gets a
// caught render error onto the beacon in production.
describe("railwatchRootOptions", () => {
  it("reports an error a boundary caught, with the component stack React only exposes here", () => {
    rootOptions().onCaughtError(new Error("render blew up"), {
      componentStack: "\n    at OrdersTable\n    at OrdersIndex",
    })
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).toMatchObject({
      name: "Error",
      message: "render blew up",
      context: { componentStack: "\n    at OrdersTable\n    at OrdersIndex" },
    })
  })

  it("reports an error no boundary caught", () => {
    rootOptions().onUncaughtError(
      new TypeError("undefined is not a function"),
      {
        componentStack: "\n    at OrdersIndex",
      },
    )
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).toMatchObject({
      name: "TypeError",
      message: "undefined is not a function",
    })
  })

  it("leaves the context off when React gave no component stack", () => {
    rootOptions().onCaughtError(new Error("render blew up"), {})
    vi.advanceTimersByTime(5000)

    expect(lastFlush().errors[0]).not.toHaveProperty("context")
  })

  it("holds a boundary-caught error to the same noise filtering as any other", () => {
    rootOptions().onCaughtError(
      new Error("ResizeObserver loop limit exceeded"),
      {},
    )
    vi.advanceTimersByTime(5000)

    expect(sendBeacon).not.toHaveBeenCalled()
  })
})
