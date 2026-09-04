# Replacing Sentry

A step-by-step migration from `sentry-ruby` / `sentry-rails` to Lantern,
in the order you'd actually do it: rip out the gem, port the initializer,
rewrite the call sites, then pick up the things Sentry has no equivalent
for. Nothing here needs a compatibility shim — every Sentry concept
either has a named counterpart or is subsumed by the execution model.

Install Lantern first ([`getting-started.md`](getting-started.md)); you
can run both for a day if you want to compare, since neither knows about
the other.

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
- **`release:`** becomes `c.deploy`, which auto-detects `LANTERN_DEPLOY`,
  then `KAMAL_VERSION`, then `GIT_REV`. It is stamped on every record,
  and it is also the release for release health, below.
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
               scheduled_tasks: 1.0, exceptions: 1.0 }
  # ...but keep every slow or failing request regardless
  c.tail_sample_slow_ms = 500

  # was excluded_exceptions: [...] (the Sentry defaults are already here)
  c.ignored_exceptions += %w[MyApp::Expected]

  # was include_local_variables: true
  c.capture_exception_locals = true

  # was send_default_pii: false, unpacked
  c.capture_request_payload = false
  c.capture_job_arguments   = false
  c.redact_headers += %w[X-Api-Key]
  c.redact_params  += %w[ssn]

  # was Sentry.set_user / config.user
  c.user { |user| { id: user.id, name: user.name, email: user.email } }
end
```

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

## Console and runner sessions

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
