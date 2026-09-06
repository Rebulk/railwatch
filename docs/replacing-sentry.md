# Replacing Sentry

A step-by-step migration from `sentry-ruby` / `sentry-rails` to Lantern.
Lantern is a genuine alternative for the Rails server workloads in the
matrix below; it is not a drop-in replacement for every product Sentry
sells. Keep both SDKs enabled during an evaluation if your application
depends on a conditional row.

Install Lantern first ([`getting-started.md`](getting-started.md)); you
can run both for a day if you want to compare, since neither knows about
the other.

## Decide whether Lantern covers your workload

Nightwatch parity and Sentry parity are different targets. Laravel
Nightwatch is an application-monitoring product built around framework
executions; Lantern deliberately maps that model onto Rails. Sentry is a
broader, multi-language managed platform with browser replay, native/mobile
SDKs, a large integration catalog, and generic tracing. Those broader
capabilities are not implied by Rails/Nightwatch parity.

| Workload or capability | Status | Boundary |
|---|---|---|
| Rails HTML/API request performance and errors | Supported | Controller/action, route, SQL, cache, render, mail, HTTP, storage, logs, and exceptions share one execution. Work performed while a streaming Rack body enumerates is tracked by [#22](https://github.com/Rebulk/lantern/issues/22). |
| Handled and unhandled Ruby exceptions | Supported | Rails.error, Rack, Active Job, manual `Lantern.report`, grouping, context, attachments, issue lifecycle, and regression detection. Delivery is memory-buffered, not a durable crash spool. |
| Active Job | Supported | Works above Solid Queue, Sidekiq, GoodJob, and other Active Job adapters. Direct `Sidekiq::Worker` and non-Solid Queue schedulers are tracked by [#29](https://github.com/Rebulk/lantern/issues/29). |
| Recurring/scheduled work | Conditional | Solid Queue recurring tasks include schedule and drift. Other schedulers need [#29](https://github.com/Rebulk/lantern/issues/29). |
| Action Cable channel actions | Conditional | Broadcast/transmit records exist; a complete action parent and child lifecycle is tracked by [#15](https://github.com/Rebulk/lantern/issues/15). |
| Distributed Rails traces | Conditional | Outgoing propagation and request/job linking exist. Upstream-sampled W3C continuity is tracked by [#16](https://github.com/Rebulk/lantern/issues/16). This is not a general OpenTelemetry collector. |
| Ruby profiling | Conditional | Requires `vernier` or `stackprof`; there is no profiler bundled into the SDK. |
| Browser monitoring | Partial | The optional Inertia client reports visits, Web Vitals, browser errors, and breadcrumbs. Session Replay, native/mobile SDKs, and Sentry's full browser/source-map workflow are outside the currently released Rails-server replacement. |
| Runtime compatibility | Narrow today | The currently proved pair is Ruby 3.4 + Rails 8.1. A maintained compatibility matrix and any safe lowering of requirements are tracked by [#26](https://github.com/Rebulk/lantern/issues/26). |
| Managed integrations and operations | Partial | Lantern Cloud supports its documented email, Slack, and webhook paths plus self-hosting. It does not promise Sentry's broader integration catalog. |
| SQL value privacy | Supported by default | Query records carry normalized SQL shapes without literal values, and Active Record binds are never sent. Raw SQL and query plans are separate opt-ins; either can contain values. |

For a Rails 8.1 application whose work enters through Rack and Active Job,
and which does not require Replay, native/mobile monitoring, or Sentry's
managed integration catalog, Lantern is a useful and valid server-side
replacement. Evaluate the conditional rows against your own production
entry points before removing Sentry.

Exception delivery has the same process boundary as the rest of Lantern's
reporter. `Lantern.record_now` skips the execution buffer, enqueues the
record, and asks the reporter for an urgent flush (within a quarter of a
second, so an exception storm ships as full batches rather than one POST
per request); it does not synchronously POST on the application thread. The reporter retries during graceful shutdown,
but its buffer is memory-only. A hard kill, OOM, or exit after the shutdown
deadline can lose records. See [Buffering, flushing, and
transport](configuration.md#buffering-flushing-transport).

## 1. Remove the gem

```ruby
# Gemfile — delete both
gem "sentry-ruby"
gem "sentry-rails"
```

```sh
bundle install
rm config/initializers/sentry.rb
```

Then grep for what's left: `rg 'Sentry\.' app lib config` — every call
site is rewritten below. Delete `SENTRY_DSN` from your secrets and
deploy config once the app boots without it.

## 2. Port the initializer

`config/initializers/lantern.rb` (written by the install generator) is
where every option from `Sentry.init` lands. The mapping:

- **`dsn:`** becomes `LANTERN_TOKEN`, one token per environment, created
  in Lantern Cloud. Self-hosting adds `LANTERN_INGEST_URL`. The token is
  also the on/off switch: with it blank, Lantern installs nothing.
- **`environment:`** becomes `c.environment`, which defaults to
  `Rails.env` — set it only to report under a different name.
- **`release:`** becomes `c.deploy`, which auto-detects the release from
  `LANTERN_DEPLOY`, the deploy platform, `REVISION`, or the Git checkout in
  the order documented in [`configuration.md`](configuration.md#core). It is
  stamped on every record, and it is also the release for release health,
  below.
- **`traces_sample_rate:`** becomes `c.sample`, a rate per execution kind
  rather than one global number: `requests`, `jobs`, `commands`,
  `scheduled_tasks`, `exceptions`. The decision is made once per
  execution, not per event, so a sampled-in request ships its whole tree
  and a sampled-out one ships nothing but an unhandled exception. Per
  route, use the `lantern_sample` / `lantern_never_sample` controller
  macros.
- **`profiles_sample_rate:`** becomes `c.profile_sample` (and/or
  `c.profile_slow_ms`) — see step 6, since it also needs a profiler gem.
- **`excluded_exceptions:`** becomes `c.ignored_exceptions`, which starts
  from the Rails-relevant subset of Sentry's own default list. Lantern
  matches the error's class *and every named ancestor*, so your own
  subclass of a listed error is ignored too. Assigning replaces the list;
  `+=` extends it.
- **`include_local_variables:`** becomes `c.capture_exception_locals`.
- **`send_default_pii:`** has no single equivalent, deliberately. It is
  split into `c.capture_request_payload` (params, and only on a request
  that raised), `c.capture_job_arguments`,
  `c.capture_response_body_on_error`, the `c.redact_headers` /
  `c.redact_params` lists, and the `c.user { }` resolver for who the
  user is. There is no "send everything" switch.
- **`config.rails.report_rescued_exceptions`** becomes
  `c.capture_rescued_exceptions`, on by default.
- **`config.rails.active_job_report_on_retry_error`** becomes
  `c.capture_job_retry_errors`, off by default because retries are usually
  expected and capturing them can flood the issues list.
- **`before_send:`** becomes `Lantern.before_ingest` plus the
  `redact_*` / `reject_*` hooks — see step 8.
- **Rack `X-Request-Start` queue time** needs no setting: it is parsed
  into `queue_time` on every `request` record.

A worked initializer, roughly what a `Sentry.init` block turns into:

```ruby
# config/initializers/lantern.rb
Lantern.configure do |c|
  c.token       = ENV["LANTERN_TOKEN"]           # was dsn:
  c.environment = ENV["APP_ENV"] || Rails.env    # was environment:
  c.deploy      = ENV["GIT_REV"]                 # was release:

  # was traces_sample_rate: 0.1
  c.sample = { requests: 0.1, jobs: 1.0, commands: 1.0,
               scheduled_tasks: 1.0, channels: 1.0, exceptions: 1.0 }
  # ...but keep every slow or failing request regardless
  c.tail_sample_slow_ms = 500
  # ...or, for failures only and a fraction of the memory: the last 200
  # child records of any sampled-out execution that raises
  c.failure_context = 200

  # was excluded_exceptions: [...] (the Sentry defaults are already here)
  c.ignored_exceptions += %w[MyApp::Expected]

  # was include_local_variables: true
  c.capture_exception_locals = true

  # was config.rails.active_job_report_on_retry_error: true
  c.capture_job_retry_errors = true

  # was send_default_pii: false, unpacked
  c.capture_request_payload = false
  c.capture_job_arguments   = false
  c.redact_headers += %w[X-Api-Key]
  c.redact_params  += %w[ssn]

  # was Sentry.set_user / config.user
  c.user { |user| { id: user.id, name: user.name, email: user.email } }
end
```

Lantern also masks credential-shaped header names (`api-key`, `access-key`,
`private-key`, `auth`, `bearer`, `credential`, `hmac`, `jwt`, `token`,
`secret`, and `signature`) automatically, including concatenated Rack aliases
such as `X-AuthToken`, `X-ApiToken`, `X-AccessToken`, `X-ClientToken`,
`X-SessionToken`, `X-RefreshToken`, `X-SecretKey`, `X-HmacSignature`, and
`X-CSRFToken`. During migration, add application-specific aliases that do not
use those names to `c.redact_headers`.

`Rails.error` needs no wiring: Lantern subscribes to it on install, so
every `Rails.error.report` / `Rails.error.handle` call already in the app
— which is how `sentry-rails` itself is normally hooked up — keeps
working unchanged.

## 3. Rewrite the call sites

| Sentry call | Lantern |
|---|---|
| `Sentry.capture_exception(e)` | `Lantern.report(e)` |
| `Sentry.capture_message("...")` | `Rails.logger.warn("...")` |
| `Sentry.set_user(id: ...)` | `Lantern.user { \|u\| ... }` (once, in the initializer) |
| `Sentry.set_tags(...)` / `set_context(...)` / `set_extras(...)` | `Lantern.context(...)` |
| `Sentry.with_scope { }` / `configure_scope { }` | `Lantern.context(...)` inside the block; `Lantern.ignore { }` where the scope existed to suppress |

```ruby
# before
Sentry.capture_exception(e)
Sentry.capture_exception(e, extra: { order_id: order.id })

# after
Lantern.report(e)
Lantern.report(e, context: { order_id: order.id })
```

`Lantern.report` defaults `severity` to `:warning` when `handled: true`
(the default) and `:error` otherwise, and tags the exception
`source: "lantern.manual"`.

**Messages.** There is no `capture_message`. Log it: every `Rails.logger`
line at or above `c.log_level` (default `:info`) becomes a `log` record,
linked to the execution it happened in and searchable on the Logs page.
Rails' own per-request noise (`Started GET`, `Processing by`, `Rendered`)
is filtered out regardless of level, because the `request` record already
carries it.

```ruby
Sentry.capture_message("cache rebuilt", level: :info)
Rails.logger.info("cache rebuilt")
```

**User.** `Sentry.set_user` scattered through controllers becomes one
resolver block, evaluated per execution:

```ruby
c.user { |user| { id: user.id, name: user.name, email: user.email } }
```

With no block set, the default reads `Current.user` if defined, else
Warden's `env["warden"].user` — so a Rails 8 auth-generator or Devise app
needs nothing at all.

**Tags, context, extras.** All three collapse into one call, which
writes through to `ActiveSupport::ExecutionContext`,
`Rails.error.set_context`, and `Rails.event.set_context` at the same
time:

```ruby
Lantern.context(tenant: org.slug, plan: org.plan, feature: :new_checkout)
```

Context is serialized onto the parent record and every exception in the
execution. `tenant` is special: it is picked up automatically from
`ActiveRecord::Base.current_tenant` / `TenantRecord.current_tenant` when
the app uses `activerecord-tenanted`, and it drives the Tenants page.

**Scopes.** A `with_scope` that added data becomes a `Lantern.context`
call inside the same block — there is no scope stack to push and pop,
because context is per execution and an execution is already the unit.
A `with_scope` that existed to *suppress* reporting becomes
`Lantern.ignore { }`, which pauses recording for the block and restores
it afterwards (nestable, via `Lantern.pause` / `Lantern.resume`).

## 4. Breadcrumbs

There is no breadcrumb API, and nothing to port. Every query, cache
read, outgoing HTTP call, log line, view render, mail delivery, and
broadcast in an execution is already its own record, linked to that
execution by `execution_id` and to the wider trace by `trace_id`. The
execution detail page shows them as a waterfall in the order they
happened, with durations — which is the breadcrumb trail Sentry
approximates, except it is complete, timed, and queryable rather than a
capped ring buffer of strings.

If you were manually adding breadcrumbs to mark progress through your own
code, that is a span (next section), not a breadcrumb.

## 5. Spans

```ruby
# before
Sentry.with_child_span(op: "pdf.render") { renderer.call }

# after
Lantern.span("pdf.render", template: "invoice", pages: 12) { renderer.call }
```

The block's value is returned untouched. Keyword arguments become the
span's attributes (up to 25, each truncated to 200 characters and run
through the same parameter filter as request params). The span records
its own duration and a `status` of `"ok"` or `"failed"`, counts toward
the parent's `spans` counter, and shows up in the execution waterfall
alongside the queries it contains. When Lantern is disabled or nothing
is recording, the block still runs — `Lantern.span` is never a behaviour
change.

## 6. Profiling

`profiles_sample_rate:` becomes two settings and one gem. Lantern does
not vendor a profiler; add the backend you want:

```ruby
gem "vernier"    # Ruby >= 3.2, preferred
gem "stackprof"  # anywhere else
```

```ruby
c.profile_sample = 0.01     # profile 1% of sampled-in executions
c.profile_slow_ms = 500     # plus every tail-kept execution over 500ms
c.tail_sample_slow_ms = 500 # ...which profile_slow_ms requires
```

With neither gem installed, `Lantern::Profiler.available?` is false and
both settings are inert. `profile_sample` decides at the start of an
execution and is cheap. `profile_slow_ms` cannot know an execution is
slow until it ends, so it profiles every tail-buffering execution and
discards the fast ones — the CPU cost is paid on all of them, which is
why it only works together with `tail_sample_slow_ms`. Raise
`c.profile_interval_us` (default 1000) if that shows up in latency.

Profiles ship as their own `profile` record — collapsed stacks, gzipped —
and the request or job is marked `profiled`. The platform renders them as
a flamegraph on the Profiles page and inline on the execution.

## 7. Attachments

```ruby
# before
Sentry.add_attachment(filename: "payload.json", bytes: request.raw_post)

# after
Lantern.attach("payload.json", request.raw_post)
Lantern.attach("invoice.pdf", Rails.root.join("tmp/invoice.pdf"))
Lantern.attach("payload.json", body, exception: error)
Lantern.report(error, attachments: { "payload.json" => body })
```

Data can be a String, a `Pathname`, or any IO. `content_type` is guessed
from the extension and can be passed explicitly. Passing `exception:`
(or using `Lantern.report(..., attachments:)`) files the attachment
against that error's issue, using the same fingerprint the exception
itself was grouped by. Payloads are gzipped on the wire and capped at
`c.max_attachment_bytes` (1 MiB by default); over the cap the record is
flagged `truncated: true` rather than dropped.

## 8. before_send

`before_send` did three different jobs. Lantern splits them, so each one
runs at the cheapest point:

```ruby
# Scrub one record type in place, at build time.
Lantern.redact_queries { |q| q[:sql] = q[:sql].gsub(/email = '[^']+'/, "email = '?'") }

# Drop records by predicate, at build time.
Lantern.reject_outgoing_requests { |r| r[:host] == "127.0.0.1" }

# Inspect or drop a whole batch, right before it's POSTed.
Lantern.before_ingest { |batch| batch.size < 10_000 }
```

The `redact_*` hooks — exactly these eight, one per record type that has
one — receive the record hash and mutate it in place:
`redact_requests`, `redact_queries`, `redact_exceptions`,
`redact_cache_events`, `redact_commands`, `redact_mail`,
`redact_outgoing_requests`, `redact_logs`. A redactor that raises drops
that record rather than the batch.

The `reject_*` hooks — exactly these eight — return truthy to drop the
record: `reject_queries`, `reject_cache_events`, `reject_mail`,
`reject_notifications`, `reject_broadcasts`, `reject_outgoing_requests`,
`reject_enqueued_jobs`, `reject_logs`. A rejector that raises fails open
(the record is kept). `Lantern.reject_cache_keys(patterns)` is the
shortcut for cache keys specifically.

`Lantern.before_ingest` runs per batch; returning `false` drops the whole
batch, returning an Array replaces it. Multiple hooks chain.

To drop a whole record type before it is ever built — cheaper than any
hook — use `c.ignore = [:cache_events, :view_renders]`.

## 9. Fingerprints

Sentry's `fingerprint` and grouping rules become one block, or a
per-call argument:

```ruby
Lantern.fingerprint do |error, default|
  error.is_a?(Faraday::Error) ? [ "upstream", error.response_status, :default ] : nil
end

Lantern.report(error, fingerprint: [ "billing", "stripe-timeout" ])
```

The block is called with the error and `default` — the array of parts
Lantern would otherwise have hashed (class, file, line, normalized
message). Return an array of strings; return nil to fall back to the
default grouping, so a resolver that doesn't recognise an error can just
say so. The literal `:default` splices the default parts in wherever you
put it, like Sentry's `{{ default }}`. A per-call `fingerprint:` wins
over the global block, and an error class of your own can define
`lantern_fingerprint` so every raise site agrees.

## 10. Release health

Automatic, and there is nothing to port. `session` records come from two
places — the browser client (`startLantern()`, one session per tab) and
a per-user server-side fallback in the request middleware, which is also
the only source that can see an unhandled exception and mark a session
`crashed`. Both key on the same id when the browser cookie is present,
so a session seen from both ends is deduped rather than double counted.

The release is `c.deploy`. A deploy is a release: no separate release
concept, no `Sentry.configure_scope { |s| s.set_release }`. Crash-free
session and crash-free user rates are shown per release on the platform's
Releases page.

```ruby
c.track_sessions = false          # LANTERN_TRACK_SESSIONS — turns both sources off
c.session_flush_interval = 60.0   # seconds between server-session flushes
c.session_timeout = 1800.0        # idle seconds before a server session ends
```

## 11. Browser errors (`@sentry/react`)

Delete `@sentry/react` too. The browser client the generator installs
(`app/frontend/lib/lantern.ts`) reports JavaScript errors on the same
beacon it already uses for visit timing and Core Web Vitals — one
transport, one batch, one flush on `pagehide` or every 5s. There is no
second SDK to load and no second quota.

```ts
// app/frontend/entrypoints/application.ts
import { startLantern } from "@/lib/lantern"

startLantern({
  // Added to the defaults, not instead of them.
  ignoreErrors: [/Failed to fetch dynamically imported module/],
  denyUrls: [/analytics\./],
  // Only if the app scopes tenants by path or subdomain: the beacon posts
  // to /lantern/beacon, which is outside that scoping, so the server
  // cannot work the tenant out for itself.
  tenant: () => /^\/orgs\/([^/]+)/.exec(location.pathname)?.[1],
})
```

| Sentry | Lantern |
|---|---|
| `Sentry.init({ dsn })` | `startLantern()`. There is no DSN: the beacon posts to the app's own origin and the *server* decides whether to record it (`c.beacon_enabled`, `LANTERN_TOKEN`). The gate you already have on whether `startLantern()` runs at all is the only gate. |
| `release` | Automatic. The record is stamped with `c.deploy`, the same release the server records carry, so a browser issue and a server issue from one deploy line up without a matching pair of settings to get wrong. |
| `environment` | Automatic — the ingest token identifies the environment. |
| `ignoreErrors` | `startLantern({ ignoreErrors })`. Strings match anywhere in the message; regexes are tested against it. Both `ResizeObserver` messages are ignored by default. |
| `denyUrls` | `startLantern({ denyUrls })`, matched against the top stack frame's URL. `/extensions\//i`, `/^chrome:\/\//i`, and `/^moz-extension:\/\//i` are denied by default, **and** any frame from an origin that isn't the app's own is dropped — extensions, injected widgets, tag managers. |
| `Sentry.setUser` | Server-side. The beacon is a same-origin POST carrying the session cookie, so the server resolves the user the same way it does for a request (`Lantern.user`) when `Current.user` or Warden is set by middleware; an app that authenticates in a `before_action` gives Lantern the same lookup with `c.beacon_user { \|request\| ... }`. Nothing the browser sends names the user, so it cannot be forged. |
| `Sentry.setTag("org", …)` | `startLantern({ tenant })`, and `Lantern.context(...)` for everything else. |
| `Sentry.captureException(e)` | `reportError(e)`. |
| `Sentry.captureMessage(text)` | `reportError(new Error(text))` — Lantern has one shape for a browser problem, not two. |
| Breadcrumbs (automatic) | Automatic: the last 20 of console errors/warnings, clicks, and Inertia navigations ride along on every error and are shown on the issue page. Click crumbs record the element, never an input's value. |
| `Sentry.ErrorBoundary` | Your own boundary plus `lanternRootOptions()` (React 19) or `reportError` (React 18) — see below. |
| `tracesSampleRate`, `replaysSessionSampleRate` | No equivalent. Lantern reports visit timing and Core Web Vitals instead of browser traces, and does not record sessions. |

### What is and is not captured

Captured: uncaught errors (`window.onerror` / the `error` event),
unhandled promise rejections, Inertia's request-failed event (`exception`
on Inertia 2, `networkError` on Inertia 3 — where a dropped connection
lands as an axios `Network Error`; reported only while the user is waiting
on a visit, meaning one that shows Inertia's progress bar or loads a page's
deferred props — a background poll, `router.reload`, or prefetch that drops
its connection has failed nothing the user did, since the page keeps what
it has and the next tick refreshes it; pass `showProgress: true` to have a
particular refresh reported), Inertia's non-Inertia-response event
(`invalid` on Inertia 2, `httpException` on Inertia 3 — the server answered
a visit with a 403 page, a login redirect, a proxy error page; an Inertia
response that merely carries a 4xx status, such as a form re-rendered with
validation errors at 422, is the app working and is not reported), and
anything the app hands to `reportError`.

Not captured: browser traces and session replay; failed resource loads
(a 404 on an `<img>` or `<script>`); errors from a cross-origin script,
which the browser reports as a bare `"Script error."` with no stack and
Lantern drops as not the app's to fix; and anything thrown before
`startLantern()` runs.

Minified frames are shown as the browser named them
(`assets/index-Bq1x9K.js:41`) — Lantern does not yet upload source maps,
so a production frame does not link to a line in your repository.

### Error boundaries: keep them, and wire the root

An error boundary is not what gets an error reported, and outside a
development build React does **not** hand a caught error back to
`window.onerror`. React 18 stops at `componentDidCatch`; React 19 routes
it to the root's `onCaughtError`, whose default is `console.error`. So a
boundary on a plain `startLantern()` app silently swallows every render
error it catches. Two lines fix that.

**React 19** — pass Lantern's root options where you create the root:

```tsx
import { createRoot } from "react-dom/client"
import { lanternRootOptions, startLantern } from "@/lib/lantern"

createRoot(el, lanternRootOptions()).render(<App {...props} />)
startLantern()
```

That covers `onCaughtError` (the one React would otherwise only log) and
`onUncaughtError` (which would reach the window listener anyway, but this
way it arrives with the component stack attached). `onRecoverableError`
is deliberately left alone: React's default already routes a hydration
mismatch through `window.reportError`, so it reaches Lantern without help,
and overriding it would take React's own console warning away from
whoever is debugging one.

**React 18**, whose roots take no error options — report from the
boundary, which is also where the component stack lives:

```tsx
import { reportError } from "@/lib/lantern"

class MapErrorBoundary extends Component<Props, State> {
  static getDerivedStateFromError() {
    return { hasError: true }
  }
  componentDidCatch(error: Error, info: ErrorInfo) {
    reportError(error, { componentStack: info.componentStack })
  }
  render() {
    return this.state.hasError ? <Fallback /> : this.props.children
  }
}
```

Either way, keep the boundaries for what they are for — rendering a
fallback instead of a blank screen. Everything passed as `reportError`'s
second argument lands in the exception's `context` on the issue page,
flattened to strings.

## 12. Console and runner sessions

Sentry never hooked `bin/rails console`: sentry-rails has no console railtie
block, so an engineer's typo at a production prompt was never an issue.
Lantern subscribes to far more than Sentry did — every query, every log line,
`Rails.error` — and starts reporter/health/session threads at boot, so it has
to say this out loud rather than inherit it by accident. It does: a console
process **captures nothing, starts no thread, and sends no `process` or
`health` record**. Turn that off with `c.capture_console = true`
(`LANTERN_CAPTURE_CONSOLE=1`) when you actually want to trace a console
session.

`bin/rails runner` is the case that needs a rule rather than a switch.
sentry-rails installs an `at_exit` hook for every runner process and reports
whatever killed it, tagged `source: "runner"`. That is right for a *deployed*
script and wrong for a *typed* one — and on this app the typed ones dominated:
four of fifteen unresolved issues were a human poking at production (a
misspelled attribute, a tenant slug that did not exist, an `unless … next`
that did not parse). So the filter is **not** "source == runner", which would
silence exactly the runner errors worth waking up for. The line is where the
code came from, and the argument says it:

| Invocation | railties runs | Treated as | Reported? |
|---|---|---|---|
| `rails runner -` | `eval($stdin.read, …, "stdin")` | interactive | no |
| `rails runner 'Some.code'` | `eval(code_or_file, …)` | interactive | no |
| `rails runner /tmp/probe.rb` | `Kernel.load` | interactive (scratch path) | no |
| `rails runner script/nightly.rb` | `Kernel.load` | deployed | **yes** |

Anything that is not a `.rb` file was typed. A `.rb` file is deployed unless
it sits under `config.interactive_runner_paths` (`/tmp/`, `/var/tmp/`) —
deliberately two literal temp roots rather than "outside `Rails.root`",
because a scheduled script going silent is the failure this must never cause.
Rake tasks, Solid Queue jobs, and recurring tasks are never interactive.

An interactive run is still *recorded*: its `command` record ships with
`interactive: true`, the `exit_code`, the duration, and the
`exception_preview`, so the run is visible on the platform without opening an
issue. Only the exception is withheld.

If your app carried an app-side version of this (a `Lantern.before_ingest`
hook matching `rails runner …` previews, or `sentry_runner_noise.rb` under
`before_send`), delete it — this is the gem's job now.

## What Lantern does that Sentry doesn't

| | |
|---|---|
| Execution-linked everything | Every query, cache read, log line, mail, broadcast, storage op, view render, and outgoing request is a record linked to the request/job/task it happened in, and shown as one waterfall. Not a sample of spans — all of it, for the executions that ship. |
| Query and N+1 detection | The same normalized query repeating past `n_plus_one_threshold` in one execution becomes an `n_plus_one` record with the app line that issued it; the platform turns that into a concrete `includes` or counter-cache suggestion, and can attach the adapter's own query plan. |
| Scheduled-task drift | Solid Queue recurring tasks report `task_key`, `schedule`, and `drift` (scheduled vs actual start) with nothing to instrument — no cron check-in calls to add or forget. |
| Rails surfaces Sentry has no record for | `cache_event`, `mail`, `broadcast`, `notification`, `storage_op`, `view_render`, `transaction`, `deprecation`, `enqueued_job`. |
| Inertia visit timing | Real browser page-visit duration, prop byte size, partial reloads, SSR time, and Core Web Vitals, from a client the generator installs. |
| Spec matchers as a CI gate | `have_lantern_queries`, `have_lantern_n_plus_one`, `have_lantern_outgoing_requests` fail the pull request that regresses a hot path. |
| Zero app-DB writes | The gem holds records in memory and ships them from a background thread; a bench gate asserts no `INSERT`/`UPDATE`/`DELETE` ever originates in `lib/lantern`. This is why it is safe on single-writer SQLite. |
| One SQLite database per environment | The platform stores each monitored environment's telemetry in its own database file, which makes retention pruning, backup, and restore per-environment operations. |
| An MCP server | AI assistants can ask what broke after the last deploy, list slow routes, read an execution's timeline, and search logs ([`ai-and-mcp.md`](ai-and-mcp.md)). |

## See also

- [`configuration.md`](configuration.md) — every option in full.
- [`records.md`](records.md) — the `exception` record's field list,
  including `fingerprint` and `fingerprint_source`.
- [`troubleshooting.md`](troubleshooting.md) — if nothing arrives after
  the cutover.
