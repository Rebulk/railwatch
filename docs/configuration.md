# Configuration

Everything below lives on `Lantern::Configuration` (`lib/lantern/configuration.rb`),
set via `Lantern.configure { |c| ... }` in `config/initializers/lantern.rb`
(created by `bin/rails generate lantern:install`). Every setting has a
`LANTERN_*` env var default; explicit values set in the initializer always
win over the env var.

## Core

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `enabled` | `LANTERN_ENABLED` | `true` | Master switch. `Lantern.enabled?` is also `false` whenever `token` is blank, so setting only `LANTERN_TOKEN` is enough to turn Lantern on. |
| `token` | `LANTERN_TOKEN` | nil | Bearer token for `/ingest`. Required. |
| `ingest_url` | `LANTERN_INGEST_URL` | `https://lantern.rebulk.com` | Platform base URL. Point at a self-hosted instance to override. |
| `deploy` | `LANTERN_DEPLOY` | `KAMAL_VERSION`, then `GIT_REV`, then nil | Version tag stamped on every record and used by `lantern:deploy`. |
| `server` | `LANTERN_SERVER` | `KAMAL_HOST`, else `Socket.gethostname` | Host stamped on every record. Under Kamal the container hostname carries a per-deploy container id, so the Kamal host wins; it is what the post-deploy hook registers as an expected server, which is what silent-host detection compares against. |
| `environment` | — | resolved lazily from `Rails.env` | Set `c.environment = "staging"` to report under a name other than the actual Rails env. |
| `ignored_request_paths` | `LANTERN_IGNORED_REQUEST_PATHS` (comma-separated) | `/up,/lantern/beacon` | Exact request paths that bypass Lantern's request execution entirely. In Ruby configuration, `Regexp` entries are also supported. Setting the env var replaces the defaults; append with `c.ignored_request_paths += ["/healthz"]` to keep them. |

`Lantern.enabled?` delegates to `config.enabled?`, which is `@enabled &&
token.present?` — there is no separate "is configured" check elsewhere.

The request middleware also recognizes the reporter's own `POST /ingest`
when Lantern Cloud monitors itself. It bypasses that request only when the
method, bearer token, configured ingest path, and public scheme/host/port all
match; an unrelated application route named `/ingest` remains observable.
Rack's normalized forwarded origin is used so this works behind a trusted
TLS-terminating proxy with `Forwarded` or `X-Forwarded-*` headers.

## Sampling

`sample` is a hash of rate per execution kind, each `0.0`–`1.0`, decided
once per execution (`Lantern::Sampler.decide`, `lib/lantern/sampler.rb`) —
not per record. A sampled-in execution ships every child record it
buffered; a sampled-out one ships nothing except an unhandled exception
(governed by its own `exceptions` rate, decided once and memoized per
execution — see `docs/records.md`'s `exception` section).

| Key | Env var | Default |
|---|---|---|
| `requests` | `LANTERN_REQUEST_SAMPLE_RATE` | `1.0` |
| `jobs` | `LANTERN_JOB_SAMPLE_RATE` | `1.0` |
| `commands` | `LANTERN_COMMAND_SAMPLE_RATE` | `1.0` |
| `scheduled_tasks` | `LANTERN_SCHEDULED_TASK_SAMPLE_RATE` | `1.0` |
| `exceptions` | `LANTERN_EXCEPTION_SAMPLE_RATE` | `1.0` |

Set as a whole hash: `c.sample = { requests: 0.1, jobs: 1.0 }` — keys you
omit keep their default (`config.sample_rate` falls back to `1.0` for an
unset kind).

**Per-route overrides**, from `ControllerHelpers`
(`lib/lantern/controller_helpers.rb`), included into every controller:

```ruby
class ReportsController < ApplicationController
  lantern_sample 0.01, only: :index      # before_action wrapping Lantern.sample(rate)
  lantern_never_sample only: :health     # before_action wrapping Lantern.dont_sample
end
```

Both accept the same options as `before_action` (`only:`, `except:`, ...).
Programmatically: `Lantern.sample(rate)` re-rolls the current execution's
sampling decision; `Lantern.dont_sample` forces it off; `Lantern.sampling?`
reads the current decision.

### Tail-based sampling

Head sampling decides at the *start* of an execution, before anything is
known about it — cheap, but it throws away exactly the slow requests you
wanted to see. Tail sampling keeps buffering a head-sampled-out
execution's child records and decides at the *end*, once the duration and
outcome are known.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `tail_sample_slow_ms` | `LANTERN_TAIL_SAMPLE_SLOW_MS` | nil (off) | Keep a head-sampled-out execution that ran at least this many milliseconds. |

With it set (or after `Lantern.keep!`), a head-sampled-out execution
ships its whole tree when it ran at least `tail_sample_slow_ms`, when
`Lantern.keep!` was called, or when it raised an unhandled exception
(subject to the `exceptions` rate); otherwise the buffered records are
discarded at the end and nothing ships. Such a tree's parent record
carries `tail_sampled: true`, so a tail-kept execution is
distinguishable from a head-sampled one.

```ruby
c.sample = { requests: 0.05 }   # keep 5% of requests...
c.tail_sample_slow_ms = 500     # ...plus every request slower than 500ms
Lantern.keep!                   # keep this one, whatever the head decision was
```

**The trade-off is memory**: with tail sampling on, every sampled-out
execution buffers its child records (queries, logs, cache events, ...)
for its lifetime instead of discarding them as they happen, capped at
`Execution::MAX_RECORDS` (10,000) per execution. With it off — the
default — `Execution#recording?` is false for a sampled-out execution and
nothing is built or buffered at all, which is the cheapest path and
exactly the behaviour Lantern had before. `Lantern.keep!` can only keep
records made *after* the call unless tail sampling was already on: what
was never buffered can't be resurrected.

### Failure context

Tail sampling buys diagnosability for sampled-out executions with the
memory to buffer *every* one of them. Failure context is the same trade
on a much shorter leash: keep a bounded ring of a head-sampled-out
execution's most recent child records, and ship it only if that
execution reports an unhandled exception.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `failure_context` | `LANTERN_FAILURE_CONTEXT` | `0` (off) | How many child records a head-sampled-out execution keeps, so an unhandled exception can ship what led up to it. |

```ruby
c.sample = { requests: 0.05 }   # keep 5% of requests...
c.failure_context = 200         # ...and the last 200 records of any that fails
```

With this set, a head-sampled-out request, job attempt, scheduled task,
or command buffers its child records in a ring of that many. If it
reports an unhandled exception — the same policy that decides whether
the exception itself ships, i.e. subject to the `exceptions` rate — the
ring is promoted, and the parent, the exception, and the retained
children all ship together, with `tail_sampled: true` on the parent. If
it completes normally the ring is discarded at the end and nothing ships,
exactly as before.

Nothing else promotes a ring. `exceptions: 0`, an exception in
`ignored_exceptions`, an exception `Lantern.report`s as handled or that a
controller's `rescue_from` swallowed, one reported inside
`Lantern.ignore` / between `Lantern.pause` and `Lantern.resume`, and an
interactive `bin/rails runner`'s error all leave the sampled-out
execution shipping exactly what it shipped before the ring existed
(nothing, or the lone parent record that gives an unhandled exception
somewhere to hang). `Lantern.sample(1.0)` and `Lantern.keep!` still work
from inside the execution, and now ship the ring's contents with it
rather than only what followed the call.

**The cost** is that a sampled-out execution builds and buffers child
records again — the ring bounds how many are *kept*, not how many are
built — so this is a fraction of what tail sampling costs, but it is not
free, which is why it is off by default. There is no separate byte
limit: every record type is already truncated where it is built (SQL at
16 KB, exception messages at 4 KB, attributes at 200 bytes), so
`failure_context` records is also the memory bound, and overflow
increments the same dropped-record counter tail sampling uses, reported
with the batch rather than swallowed.

`failure_context` and `tail_sample_slow_ms` are independent. With both
set, tail sampling's larger buffer wins for the whole execution: it keeps
everything, up to `Execution::MAX_RECORDS`, and promotes on duration as
well as on failure.

### Profiling

Sampling and tail sampling say *which* executions ship; profiling says
which of them also ship a stack profile — where the time inside a slow
request or job actually went (`docs/records.md`'s `profile` record).

The backend is an optional dependency the app installs itself, because
neither belongs in every Gemfile:

```ruby
gem "vernier"    # Ruby >= 3.2, preferred
gem "stackprof"  # anywhere else
```

With neither installed, `Lantern::Profiler.available?` is false and every
option below is inert.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `profile_sample` | `LANTERN_PROFILE_SAMPLE_RATE` | `0.0` (off) | Fraction of sampled-in executions to profile, rolled once per execution. |
| `profile_slow_ms` | `LANTERN_PROFILE_SLOW_MS` | nil (off) | Also ship a profile for any tail-buffering execution that ran at least this many milliseconds. |
| `profile_interval_us` | `LANTERN_PROFILE_INTERVAL_US` | `1000` | Sampling interval in microseconds. |
| `profiler` | `LANTERN_PROFILER` | nil (auto) | Pin a backend: `vernier` or `stackprof`. Auto prefers vernier when both are installed. |

The two triggers are different bargains:

- **`profile_sample`** decides at the *start*, like head sampling. A
  profiler runs for that fraction of executions and every profile it takes
  is shipped. Cheap and predictable — 1% of requests pay for a profiler,
  99% pay for one `Random.rand`.
- **`profile_slow_ms`** can't know an execution is slow until it is over,
  so it profiles *every* tail-buffering execution from its first line and
  throws away the ones that turn out to be fast. That means it only works
  together with `tail_sample_slow_ms` (nothing tail-buffers without it),
  and **the CPU cost is paid on every execution, not just the slow ones**
  — the profiler's sampling thread runs throughout, and the stack table it
  builds is held for the execution's lifetime. Raise
  `profile_interval_us` if that shows up in your latency; a 5000µs
  interval still resolves a 500ms request perfectly well.

```ruby
c.sample = { requests: 1.0 }
c.tail_sample_slow_ms = 500     # keep every request slower than 500ms...
c.profile_slow_ms = 500         # ...and profile it
c.profile_sample = 0.01         # plus a profile of 1% of everything else
```

Both backends are process-global, so there is one profiler per process:
an execution that starts while another is being profiled simply isn't
profiled. In the Rails `test` env profiling is skipped entirely unless
`profile_sample` is explicitly non-zero, so a suite that inherits the
app's `LANTERN_*` environment doesn't start a real profiler on every
example.

## Distributed tracing

Lantern propagates W3C trace context, so a request that fans out to
other Lantern-instrumented services shows up as one trace.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `propagate_traces` | `LANTERN_PROPAGATE_TRACES` | `true` | Send a `traceparent` header on outgoing Net::HTTP and `Lantern::Faraday` requests. |
| `trace_propagation_hosts` | `LANTERN_TRACE_PROPAGATION_HOSTS` (comma-separated) | nil (every host) | Allow list of hostnames. An entry starting with `.` matches as a suffix (`.internal` matches `api.internal`); anything else must match the host exactly. |

Outgoing: `traceparent: 00-<trace_id>-<execution_id[0,16]>-<flags>`, with
flags `01` when the execution is sampled and `00` when it isn't — a
sampled-out execution still propagates, it just says so. A `traceparent`
the app set itself is never overwritten.

Inbound: the Rack middleware parses `HTTP_TRACEPARENT` and adopts its
trace id and parent id for this execution (a malformed header is
ignored, and the execution starts its own trace). If the upstream flags
say the trace is sampled, the downstream execution is kept
(`Lantern.keep!`, above) whatever its own head decision was — otherwise
the trace would have a hole exactly where this service should be.

## Ignoring whole record types

`ignore` drops a record type before it's ever built — cheaper than
filtering after the fact, and the only way to stop the highest-volume
types (`query`, `cache_event`, `log`) at the source.

| Value | Env var |
|---|---|
| `:queries` | `LANTERN_IGNORE_QUERIES` |
| `:cache_events` | `LANTERN_IGNORE_CACHE_EVENTS` |
| `:mail` | `LANTERN_IGNORE_MAIL` |
| `:broadcasts` | `LANTERN_IGNORE_BROADCASTS` |
| `:notifications` | `LANTERN_IGNORE_NOTIFICATIONS` |
| `:outgoing_requests` | `LANTERN_IGNORE_OUTGOING_REQUESTS` |
| `:storage_ops` | `LANTERN_IGNORE_STORAGE_OPS` |
| `:view_renders` | `LANTERN_IGNORE_VIEW_RENDERS` |
| `:logs` | `LANTERN_IGNORE_LOGS` |
| `:transactions` | `LANTERN_IGNORE_TRANSACTIONS` |
| `:deprecations` | `LANTERN_IGNORE_DEPRECATIONS` |
| `:sessions` | `LANTERN_IGNORE_SESSIONS` |

```ruby
c.ignore = [:cache_events, :transactions]
```

Setting an unknown type raises `ArgumentError` immediately (this is
validated at assignment, not silently dropped). Note `query` and
`n_plus_one` records both key off `:queries`; `notification` off
`:notifications`; see `Lantern::PLURALS` in `lib/lantern.rb` for the full
singular-to-plural mapping used everywhere ignore/redact/reject hooks key
by plural.

## Redaction

Two built-in filters, both string lists, both merged with what the app
already hides:

| Attribute | Env var | Default |
|---|---|---|
| `redact_headers` | `LANTERN_REDACT_HEADERS` (comma-separated) | `Authorization,Cookie,Set-Cookie,Proxy-Authorization,X-CSRF-Token,X-XSRF-TOKEN` |
| `redact_params` | `LANTERN_REDACT_PARAMS` (comma-separated) | `password,password_confirmation,authenticity_token,_token` |

`redact_params` is merged with `Rails.application.config.filter_parameters`
at first use (`Lantern::Redactor#param_filter`), so anything the app
already scrubs from its own logs is scrubbed here too, with no extra
config. Request params are only captured at all when
`capture_request_payload` is on, and even then only for a request that
raised an exception (see `request` in `docs/records.md`).

**Per-field redaction blocks** run after a record is built, before it's
buffered — the block receives and can mutate the record hash in place:

```ruby
Lantern.redact_queries    { |q| q[:sql] = q[:sql].gsub(/email = '[^']+'/, "email = '?'") }
Lantern.redact_requests   { |r| ... }
Lantern.redact_exceptions { |e| ... }
Lantern.redact_cache_events { |c| ... }
Lantern.redact_commands   { |c| ... }
Lantern.redact_mail       { |m| ... }
Lantern.redact_outgoing_requests { |o| ... }
Lantern.redact_logs       { |l| ... }
```

A redactor that raises drops the record entirely (logged via
`Lantern.debug`, never raised into app code).

## Rejection

Drop a record entirely based on its content — for the record types that
don't have a matching `redact_*`:

```ruby
Lantern.reject_queries            { |q| q[:sql].include?("solid_queue") }
Lantern.reject_cache_events       { |c| ... }
Lantern.reject_mail               { |m| ... }
Lantern.reject_notifications      { |n| ... }
Lantern.reject_broadcasts         { |b| ... }
Lantern.reject_outgoing_requests  { |r| r[:host] == "127.0.0.1" }
Lantern.reject_enqueued_jobs      { |j| ... }
Lantern.reject_logs               { |l| ... }
```

`Lantern.reject_cache_keys(prefixes)` is a shortcut that appends to
`config.ignored_cache_key_prefixes`, matched by `Configuration.match_cache_key?`:
a `Regexp` matches as-is; a `String` starting with `^` (or containing
another regex metacharacter) is compiled as one; a `String` ending in `*`
matches as a prefix; anything else must match the key exactly.

```ruby
Lantern.reject_cache_keys %w[session: rack::attack* ^feature_flag_\d+$]
```

A rejector block returning truthy drops the record before it's buffered;
a raising rejector is treated as "don't reject" (fails open, logged via
`Lantern.debug`).

## before_ingest

Runs once per batch, right before it's POSTed — the last chance to
inspect or drop records as a group (redact/reject hooks above run
per-record, earlier, at record-build time):

```ruby
Lantern.before_ingest { |batch| batch.size < 10_000 }   # return false to drop the whole batch
Lantern.before_ingest { |batch| batch.reject { |r| r[:t] == "log" } }  # return an Array to replace it
```

Multiple hooks chain; any hook returning `false` drops the batch and
skips remaining hooks (`Lantern.run_before_ingest`, `lib/lantern.rb`).

## Buffering, flushing, transport

One background thread per process (`Lantern::Reporter`,
`lib/lantern/reporter.rb`), re-armed after fork so each Puma cluster
worker / Solid Queue forked worker gets its own. Never touches the app
database.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `buffer_size` | `LANTERN_BUFFER_SIZE` | `10000` | Max buffered records (`Lantern::Buffer`). Oldest is dropped (and counted) when full — never blocks the request thread. Keep it at or above `Execution::MAX_RECORDS` (10,000): a kept execution's whole tree is written here at once when it ends, and a queue smaller than the tree drops the tree's own oldest records first. |
| `flush_interval` | `LANTERN_FLUSH_INTERVAL` | `2.0` (seconds) | Background thread wakes and flushes on this cadence even if the buffer never fills. |
| `flush_threshold` | `LANTERN_FLUSH_THRESHOLD` | `500` | A `write` that pushes the buffer past this size wakes the thread immediately instead of waiting for the next interval. |
| `connect_timeout` | `LANTERN_CONNECT_TIMEOUT` | `1.0` (seconds) | TCP connect timeout for the ingest POST. |
| `timeout` | `LANTERN_TIMEOUT` | `3.0` (seconds) | Read/write timeout for the ingest POST. |
| `shutdown_timeout` | `LANTERN_SHUTDOWN_TIMEOUT` | `2.0` (seconds) | Deadline for the reporter thread to deliver retained records during `at_exit`. This is the number a Kamal `drain_timeout` needs to clear — see `lantern-cloud/config/deploy.yml`'s own comment on this. |

Delivery (`Lantern::Transport::Http`, `lib/lantern/transport/http.rb`):
gzip NDJSON POST to `{ingest_url}/ingest`, one retry on a raised error or
a 5xx within each delivery attempt. If that still fails — or ingest returns
402, 408, or 429 — the immutable batch and its prior drop count are retained
for retry. Every newly formed batch gets an `X-Lantern-Batch-Id` UUID which is
reused for the immediate HTTP retry and every later reporter retry; the
platform can therefore return the first committed result without inserting
the payload twice. Records written while a request is in flight collect in a
separate bounded buffer, so they never change the retained request's identity.
At most one retained batch plus one live buffer are held in memory. The
reporter retries with jittered exponential backoff (one second up to 60
seconds); it does not busy-loop. A 401 marks the transport
permanently unauthorized (no further HTTP attempts for the process's
lifetime); it and other permanent client rejections are reported through
`on_unrecoverable`. Delivery never raises into app code.

`Lantern.flush` forces an immediate flush (also called by the `command`
patches after a rake task/runner invocation finishes, so short-lived
processes don't lose their last batch to the flush interval). An unhandled
exception (`Lantern.record_now` → `Reporter#write_now`) enqueues and wakes
the reporter immediately; it never performs network I/O or a timeout cycle
on the application thread.

During shutdown the reporter immediately attempts any retained batch and
keeps retrying within `shutdown_timeout`. If the deadline expires, the batch
remains accounted for in memory and `on_unrecoverable` receives the unsent
record/drop counts. The buffer is deliberately memory-only: a hard kill or
process exit after that deadline cannot preserve records for the next boot.

## Query and view thresholds

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `slow_query_threshold_ms` | `LANTERN_SLOW_QUERY_MS` | `5.0` | Above this, a query's source location is resolved fresh instead of reused from the group cache (see `query` in `docs/records.md`). |
| `n_plus_one_threshold` | `LANTERN_N_PLUS_ONE_THRESHOLD` | `5` | Same query group repeating this many times in one execution fires one `n_plus_one` record. |
| `max_view_renders_per_execution` | — (code only) | `20` | Caps stored `view_render` records per execution; all renders still count toward the parent's `view_renders` counter regardless of the cap. |
| `capture_query_explain` | `LANTERN_CAPTURE_QUERY_EXPLAIN` | `false` | Attach the adapter's own query plan to slow `SELECT`s as the `query` record's `explain` field. The EXPLAIN runs on the same connection the query just used, with Lantern paused so it never records itself, and is rate-limited to one per query shape per process per 10 minutes. Off by default: it doubles the round trips for the queries it fires on. |
| `explain_threshold_ms` | `LANTERN_EXPLAIN_THRESHOLD_MS` | `100.0` | Minimum query duration before `capture_query_explain` will explain it. |

## Process health

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `health_interval` | `LANTERN_HEALTH_INTERVAL` | `15.0` | Seconds between `health` records (Puma thread pool, Active Record pool, Solid Queue backlog — see `health` in `docs/records.md`). One background thread per web/worker process; never runs in a console, a rake task, or the `test` env. |

Lantern re-arms the reporter and sampler after `fork` (a `Process._fork`
hook), so clustered Puma workers and forked Solid Queue workers each get a
fresh buffer, transport policy state, process record, and health thread.
The child never flushes records or drop accounting inherited from its
parent, and no `on_worker_boot` configuration is needed.

### Release health

`session` records count sessions per deploy, which is what the platform's
crash-free session and crash-free user rates are computed from — the
`deploy` on every record *is* the release.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `track_sessions` | `LANTERN_TRACK_SESSIONS` | `true` | Master switch for both session sources. Off means the request middleware does nothing extra and no flusher thread is started. |
| `session_flush_interval` | `LANTERN_SESSION_FLUSH_INTERVAL` | `60.0` | Seconds between server-session flushes. One background thread per web process, re-armed after `fork` exactly like the health sampler, and flushed once more on shutdown. |
| `session_timeout` | `LANTERN_SESSION_TIMEOUT` | `1800.0` | Seconds a server session may sit idle before it ships with `ended` and is forgotten. |

There are two sources, and they meet on the same id:

- **The browser client** (`app/frontend/lib/lantern.ts`, installed by
  `lantern:install`) mints one id per tab in `sessionStorage` and mirrors it
  into a `lantern_session` cookie. It rides along on the beacon flushes the
  client already sends for visits, so this costs no extra requests. This is
  the primary source for a web app, and it is what makes session duration
  mean "how long the tab was open".
- **The request middleware** aggregates, in memory, every request that either
  resolves a user or carries that cookie (or an `X-Lantern-Session` header) —
  the only source for an API-only app, and the only one that can see an
  unhandled exception, which is what makes a session `crashed`.

When a browser session's requests carry the cookie both sources produce
records under the same id and the platform dedupes them.

## Vendor noise defaults

Framework/vendor activity excluded by default so a fresh install isn't
dominated by Rails' own housekeeping:

| Attribute | Env var | Default | Affects |
|---|---|---|---|
| `capture_default_vendor_commands` | `LANTERN_CAPTURE_DEFAULT_VENDOR_COMMANDS` | `false` | `Configuration::DEFAULT_VENDOR_COMMANDS`: `db:migrate`, `db:schema:load`, `db:schema:dump`, `db:seed`, `db:prepare`, `assets:precompile`, `assets:clobber`, `tmp:cache:clear`, `log:clear`. |
| `capture_default_vendor_cache_keys` | `LANTERN_CAPTURE_DEFAULT_VENDOR_CACHE_KEYS` | `false` | `Configuration::DEFAULT_VENDOR_CACHE_KEYS`: `rack::attack`, `flipper`, `solid_cable`, `active_storage`, `migration_`, `schema_cache` prefixes. |
| `capture_framework_events` | `LANTERN_CAPTURE_FRAMEWORK_EVENTS` | `false` | Rails 8.1 structured `Rails.event` events under `action_controller.*`, `active_record.*`, etc. — already redundant with the `request`/`job_attempt` records, so off by default. |

`ignored_cache_key_prefixes` (code only, no env var — use
`Lantern.reject_cache_keys` above) is separate from these vendor
defaults and always applies.

## Interactive sessions: console and runner

An engineer poking at production from a shell is not the application failing.
Sentry never hooked `bin/rails console` at all, and Lantern keeps that
behaviour — while making sure a deployed script still reports.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `capture_console` | `LANTERN_CAPTURE_CONSOLE` | `false` | When `false`, a `bin/rails console` process captures nothing — no exceptions, queries, or logs — starts no reporter/health/session thread, and sends no `process` or `health` record. Set it to `true` for the rare "trace what I'm about to do in here" session. Detected from `Rails::Console`, which railties defines before the app boots (`lib/lantern/console.rb`). |
| `interactive_runner_paths` | `LANTERN_INTERACTIVE_RUNNER_PATHS` (comma-separated) | `Configuration::DEFAULT_INTERACTIVE_RUNNER_PATHS`: `/tmp/`, `/var/tmp/` | Scratch roots. A `bin/rails runner` given a `.rb` file under one of these is treated as hand-written (typed in a shell inside a container) rather than deployed. |

`bin/rails runner` is classified by **where the code came from**, which is
the only thing that separates a typo from a cron job:

| Invocation | Treated as | Result |
|---|---|---|
| `rails runner -` | interactive | `command` record with `interactive: true`, no exception reported |
| `rails runner 'Some.code'` | interactive | same |
| `rails runner /tmp/probe.rb` | interactive | same (a `.rb` file under `interactive_runner_paths`) |
| `rails runner script/nightly.rb` | deployed | `command` record and the exception, as before |

An interactive run is still recorded: the `command` record ships with its
`exit_code`, duration, and `exception_preview`, so you can see that someone
ran something and that it died — it just doesn't open an issue. Rake tasks
and Solid Queue jobs are never interactive.

## Exception source and request payload

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `capture_exception_source` | `LANTERN_CAPTURE_EXCEPTION_SOURCE_CODE` | `true` | Include source snippet lines with each exception's backtrace frames. |
| `capture_exception_locals` | `LANTERN_CAPTURE_EXCEPTION_LOCALS` | `false` | Snapshot the raising frame's local variables (up to 25, values truncated to 200 chars, run through the same filter as request params) onto each exception, like Sentry's locals panel. Installs a `TracePoint(:raise)`; opt in per environment. |
| `capture_request_payload` | `LANTERN_CAPTURE_REQUEST_PAYLOAD` | `false` | Capture (redacted) request params — only for a request that raised, never otherwise. |
| `capture_job_arguments` | `LANTERN_CAPTURE_JOB_ARGUMENTS` | `false` | Add the job's real arguments (`job.serialize["arguments"]`) to each `job_attempt`/`scheduled_task` record, capped at 8 KiB of JSON. Hash arguments run through the same filter as request params. Off by default because job arguments routinely carry PII; `arguments_preview` (argument *shapes* only) is always on regardless. |
| `capture_response_body_on_error` | `LANTERN_CAPTURE_RESPONSE_BODY_ON_ERROR` | `false` | Add the first 4 KiB of the response body to an `outgoing_request` record when the response was an error (status ≥ 400, or the call raised). A JSON object body is filtered like request params and re-serialized; anything else is stored as it arrived. Off by default — a third party's error body is arbitrary data you didn't write. |
| `ignored_exceptions` | `LANTERN_IGNORED_EXCEPTIONS` (comma-separated) | `Configuration::DEFAULT_IGNORED_EXCEPTIONS` | Class names never captured, handled or not. The default list is Sentry's Rails-relevant exclusions plus `SignalException` (a SIGTERM/SIGINT ending a process is a shutdown, not an error; rake and runner also close their command record with exit code 128+signal instead of reporting). Matched against the error's class *and every named ancestor*, so your own subclass of a listed error is ignored too. Setting the env var replaces the default list; append instead with `c.ignored_exceptions += ["MyApp::Expected"]`. |
| `capture_rescued_exceptions` | `LANTERN_CAPTURE_RESCUED_EXCEPTIONS` | `true` | Capture exceptions a controller swallows with `rescue_from` (Rails' `rescue_from_callback.action_controller` notification) as `handled: true`, `severity: :warning`, `source: "action_controller.rescue_from"`. Sentry calls this `report_rescued_exceptions`. |

`DEFAULT_IGNORED_EXCEPTIONS` is the Rails-relevant subset of Sentry's own
`excluded_exceptions` defaults — routine 4xx plumbing rather than
application bugs:

`ActionController::BadRequest`, `ActionController::InvalidAuthenticityToken`,
`ActionController::RoutingError`, `ActionController::UnknownFormat`,
`ActionController::UnknownHttpMethod`,
`ActionDispatch::Http::MimeNegotiation::InvalidType`,
`ActionDispatch::Http::Parameters::ParseError`,
`ActiveRecord::RecordNotFound`, `Puma::HttpParserError`,
`Puma::HttpParserError501`, `Rack::QueryParser::InvalidParameterError`,
`Rack::QueryParser::ParameterTypeError`.

Note that Rails never reports an exception that has a `rescue_response`
(`ActiveRecord::RecordNotFound` → 404) to `Rails.error` in the first
place, so several of these are belt-and-braces for the paths that *do*
reach Lantern — jobs, `Lantern.report`, and `rescue_from`.

## Logging

| Attribute | Env var | Default |
|---|---|---|
| `log_level` | `LANTERN_LOG_LEVEL` | `:info` |

Only `Rails.logger` lines at or above this level become `log` records.
Rails' own per-request/job noise (`"Started GET"`, `"Processing by"`,
`"Rendered"`, etc.) is filtered regardless of level, since the
`request`/`job_attempt` records already carry that information.

## User resolution

```ruby
c.user { |user| { id: user.id, name: user.name, email: user.email } }
```

Default (no block set): reads `Current.user` (authentication-zero /
Rails 8 auth generator convention) if defined, else Warden's `env["warden"].user`
(Devise). The resolved id is memoized per user per process-hour so a
`user` record ships once, not once per request (`Lantern::Subscribers::Users`,
`docs/records.md`'s `user` section).

A request resolves its user at the end, but a job enqueued mid-action needs
one immediately, so `JobTracing#serialize` resolves the enqueuing
execution's user and tenant and puts those two identifier strings into the
Active Job payload (`lantern_user`/`lantern_tenant`). The worker restores
them before the attempt records anything, so a `job_attempt` and every
child record under it are attributed to the person whose request enqueued
the job rather than to a worker process that has no signed-in user — and a
job that enqueues a job passes the same identity on. Nothing but the two
strings crosses the queue; no model is serialized or hydrated. Payloads
carry the keys only when there is something to carry, and a payload without
them falls back to local resolution, so a queue drained across a deploy
keeps working. See `docs/records.md`'s `job_attempt` section for retries,
scheduled jobs, and the cardinality note.

```ruby
c.beacon_user { |request| Session.find_by(id: request.cookie_jar.signed[:session_token])&.user }
```

Who is behind a browser beacon (visits, browser sessions, JavaScript
errors). The beacon is handled by the gem's engine controller, outside your
`ApplicationController`, so an app that authenticates in a `before_action`
-- a signed session cookie looked up per request -- has not run it when the
beacon arrives, and `Current.user` is nil there. Give Lantern the same
lookup; it hands the result to the `user` block above. Not needed when
`Current.user` is set in middleware or by Warden.

## Tenant / context

```ruby
Lantern.context(tenant: org.slug, plan: org.plan)
```

Writes through to `ActiveSupport::ExecutionContext`, `Rails.error.set_context`,
and `Rails.event.set_context` in one call (`Lantern::Context.set`,
`lib/lantern/context.rb`) — so context set for Lantern also shows up
anywhere else Rails' own context stores are read. Serialized onto every
record's `context` field (truncated at 64KB). `tenant` specifically is
auto-detected with no explicit `Lantern.context` call needed when the app
uses `activerecord-tenanted` (`ActiveRecord::Base.current_tenant`) or
`TenantRecord` (`TenantRecord.current_tenant`) — `Context.current_tenant`
checks both. The tenant is re-read while it is still nil, so a tenant bound
*inside* the execution (activerecord-tenanted's `TenantSelector` middleware
sits under Lantern's, as do `around_action`s and a job's `with_tenant`
block) still lands on the request/job record and every child made after
the bind. Records made before the bind (a `before_action` that loads the
user, say) keep `tenant: nil`.

## Inertia: beacon and SSR

`beacon_enabled` (`LANTERN_BEACON`, default `true`) gates
`POST /lantern/beacon`, mounted by the install generator
(`mount Lantern::Engine, at: "/lantern"`) — see `visit` and `exception` in
`docs/records.md` for the full field lists and client batching behavior.
The same beacon carries visit timing, Core Web Vitals, browser sessions,
and every JavaScript error the page throws; turning `beacon_enabled` off
turns off all four. Client setup: call `startLantern()` (generated at
`app/frontend/lib/lantern.ts`) from your Inertia entrypoint.

`startLantern` takes three optional settings, none of which has a
server-side equivalent — they are decisions about the browser the code is
running in:

```ts
startLantern({
  // Messages never worth an issue, added to the defaults (both
  // "ResizeObserver loop ..." messages). Strings match anywhere in the
  // message; regexes are tested against it.
  ignoreErrors: [/Failed to fetch dynamically imported module/],
  // Scripts whose failures are not this app's, matched against the top
  // stack frame's URL and added to the defaults (/extensions\//i,
  // /^chrome:\/\//i, /^moz-extension:\/\//i). A frame from any origin
  // other than the app's own is dropped regardless.
  denyUrls: [/analytics\./],
  // Only for apps that scope tenants by path or subdomain: the beacon
  // posts to /lantern/beacon, outside that scoping, so the server cannot
  // resolve the tenant itself. Read on every flush. A tenant the server
  // does resolve (`Context.current_tenant`) always wins.
  tenant: () => /^\/orgs\/([^/]+)/.exec(location.pathname)?.[1],
})
```

The same file exports two more things. `lanternRootOptions()` returns
React 19's `onCaughtError`/`onUncaughtError` root options —
`createRoot(el, lanternRootOptions())` — which is what reports an error a
boundary caught, since React only sends those to `console.error` outside
a development build. `reportError(error, context?)` reports an error the
app caught itself, and is how a React 18 boundary's `componentDidCatch`
does the same thing. See
[`docs/replacing-sentry.md`](replacing-sentry.md) for what is and is not
captured versus `@sentry/react`.

SSR timing needs no configuration: `Lantern::Patches::Inertia` prepends
`InertiaRails::Renderer#ssr_render` whenever `inertia_rails` SSR is
enabled, and the resulting `ssr_ms` lands on the `request` record's
`inertia` field automatically.

## Direct queues and schedulers

Active Job is automatic for every queue adapter. If an application uses
`Sidekiq::Job`/`Sidekiq::Worker` directly, Lantern installs Sidekiq client
and server middleware only when Sidekiq is already loaded; Sidekiq is not a
runtime dependency of the gem. The middleware skips Active Job's wrapper.

| Capability | Active Job | Direct Sidekiq | Another direct adapter |
|---|---|---|---|
| Enqueue + attempt records | Automatic | Automatic | Call the SPI lifecycle |
| Trace, user, tenant propagation | Automatic | Automatic | Use `inject_context!` / `extract_context` |
| Retry/outcome | `retry_on`, discard, abort | Retry remaining vs exhausted/dead/retry-disabled | Supply `will_retry` metadata |
| Recurring task key/schedule/drift | Solid Queue automatic; sidekiq-cron marker survives Active Job serialization | sidekiq-cron automatic | Implement `schedule_metadata` |
| Queue depth/latency/workers | Solid Queue automatic | Sidekiq API automatic once active | Implement `queue_health` |

For system cron, GoodJob cron without an adapter, or any scheduler where a
single explicit check-in is preferable:

```ruby
Lantern.scheduled_task("billing.nightly", schedule: "0 2 * * *",
                       run_at: scheduled_time, adapter: "cron") do
  Billing::Rollup.call
end
```

The block's value and exception are untouched. A successful run emits a
`scheduled_task` with `status: "processed"`; a raised exception is linked to
the task and re-raised after the task is marked failed. `run_at` is optional;
when supplied it produces scheduler drift.

Direct Sidekiq retry status follows Sidekiq's built-in `retry: false`, attempt
limit, and `retry_for` rules, including their version difference: Sidekiq 7
still applies the attempt ceiling when `retry_for` is present, while Sidekiq 8
uses only the duration. A forced Sidekiq shutdown is reported as released and
does not create an application exception because Sidekiq requeues that
unacknowledged work regardless of its retry settings. A worker's
`sidekiq_retry_in` callback runs only after every server middleware has unwound,
so a callback that returns
`:discard` or `:kill` cannot be observed reliably at attempt-record time; that
attempt may appear as `"released"` even though Sidekiq subsequently discards
or kills it. The exception and attempt are still captured.

Custom integrations register an object with `Lantern::JobAdapters.register`.
The optional methods are `available?`, `install!`,
`schedule_metadata(payload)`, and `queue_health`. Middleware uses
`instrument_enqueue` and `instrument_perform`; a scheduler wraps its enqueue
with `JobAdapters.with_schedule(task_key:, schedule:, run_at:)` so direct and
Active Job clients serialize the same marker. See the built-in Sidekiq adapter
for the complete, dependency-safe contract.

## Manual reporting and instrumentation

```ruby
Lantern.report(error, handled: true, context: { order_id: order.id })
Lantern.ignore { ExpensiveSync.run }          # pause recording for the block, restored after
Lantern.instrument_outgoing(:get, url) { http_client.get(url) }  # for HTTP clients without a dedicated patch
```

`Lantern.report` defaults `severity` to `:warning` when `handled: true`,
`:error` otherwise, and tags `source: "lantern.manual"`.
`Lantern.instrument_outgoing` records an `outgoing_request` only if the
block's return value responds to `#status` — for Faraday-alike client
objects that aren't Net::HTTP and don't already go through
`Lantern::Faraday` middleware.

### Fingerprinting

How an exception is bucketed into an issue. The default is class + top
in-app frame + normalized message (see
[`docs/records.md`](records.md)'s `exception` section for what
normalization removes). Three ways to override it, in precedence order:

```ruby
# 1. Per call, when you already know the bucket.
Lantern.report(error, fingerprint: [ "payments", gateway.name ])

# 2. On your own error class, so every raise site agrees.
class PaymentError < StandardError
  def lantern_fingerprint = [ "payments", gateway ]
end

# 3. Globally, in an initializer (one block; Sentry's before_send fingerprint).
Lantern.fingerprint do |error, default|
  error.is_a?(Faraday::Error) ? [ "upstream", error.response_status, :default ] : nil
end
```

The block is called with the error and `default` — the Array of parts
Lantern would have hashed (`[class, file, line, normalized message]`). It
returns an Array of strings/symbols/numbers; the literal `:default`
splices those default parts in wherever you put it (Sentry's
`{{ default }}`). Parts are stringified, empty ones dropped, and the
result capped at 10 parts of 200 chars. Returning nil or an empty Array —
or raising — falls back to the default, so a bad resolver can never lose
an exception. Every `exception` record carries the parts it was hashed on
(`fingerprint`) and where they came from (`fingerprint_source`), and an
attachment filed against the error (`Lantern.attach(..., exception:)`)
follows the same rule, so it lands on the same issue.

### Attachments

Ship an arbitrary blob — the payload that failed to parse, a rendered PDF,
the webhook body a customer swears they sent — as its own `attachment`
record (Sentry's `Sentry.add_attachment`):

```ruby
Lantern.attach("payload.json", request.raw_post)                  # a String
Lantern.attach("invoice.pdf", Rails.root.join("tmp/invoice.pdf")) # a Pathname, or any IO
Lantern.attach("payload.json", body, content_type: "text/plain")  # override the guessed type
Lantern.attach("payload.json", body, exception: error)            # file it against an issue
Lantern.report(error, attachments: { "payload.json" => body })    # capture + attach in one call
```

`content_type` defaults to whatever Marcel makes of the name's extension
(`application/octet-stream` if it can't tell). Passing `exception:` sets
the record's `exception_group_hash` to the same group hash the `exception`
record is filed under, so the platform shows the attachment on that issue.
An attachment made inside a recording execution belongs to it; made with
nothing executing, it ships standalone. Returns nil and records nothing
when Lantern is disabled or the payload is empty.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `max_attachment_bytes` | `LANTERN_MAX_ATTACHMENT_BYTES` | `1048576` (1 MiB) | Payloads longer than this are cut to the cap and the record is flagged `truncated: true`. `bytes` on the record is always the stored size. Data is gzipped and base64-encoded on the wire, so the cap is on the *original* bytes, not what ships. |

## on_unrecoverable

```ruby
Lantern.on_unrecoverable { |error| Rails.error.report(error, handled: true) }
```

Called whenever Lantern rescues one of its own internal errors, ingest
permanently rejects a batch, or shutdown expires with retained records that
could not be sent. Retryable delivery failures stay buffered and do not fire
the callback on every attempt. With no callback registered, this falls back
to `Lantern.debug` (stderr, gated on `LANTERN_DEBUG`, never `Rails.logger` —
so gem-internal failures can never themselves become `log` records).

## Faraday

Opt in per connection (only needed for a non-default Faraday adapter;
the default adapter is Net::HTTP, already covered globally):

```ruby
Faraday.new(url) { |f| f.use Lantern::Faraday }
```

## debug

| Attribute | Env var | Default |
|---|---|---|
| `debug` | `LANTERN_DEBUG` | `false` |

Internal diagnostics to stderr (`warn`, prefixed `[lantern]`) — deliberately
not `Rails.logger`, so turning this on can't create a feedback loop of
`log` records about Lantern's own failures.

## Public facade — full method list

Mirrors Laravel Nightwatch's facade shape. All on the `Lantern` module
(`lib/lantern.rb`) unless noted:

`configure`, `config`, `enabled?`, `sample(rate)`, `dont_sample`,
`keep!`, `sampling?`, `span(name, **attributes) { }`,
`scheduled_task(task_key, schedule:, run_at:, adapter:) { }`, `ignore { }` / `pause` / `resume` / `paused?` (pause/resume
are the ignore block's building blocks — nestable), `record(type, **fields)`,
`report(error, ..., attachments: {}, fingerprint: [])`, `attach(name, data, ...)`, `context(**attrs)`, `user(&block)`,
`fingerprint(&block)`, `redact_*`,
`reject_*`, `reject_cache_keys`, `before_ingest`, `on_unrecoverable`,
`instrument_outgoing`, `flush`, `debug { }`.

## Rake tasks

Ship with the gem via Rails::Engine's default `lib/tasks` convention
(`lib/tasks/lantern_tasks.rake`):

- **`lantern:status`** — pings `{ingest_url}/ingest/ping` with the
  configured token; aborts if `LANTERN_TOKEN` is unset or the ping fails.
- **`lantern:doctor`** — prints a ✓/✗ checklist of the whole install: token,
  ingest URL, `GET /ingest/ping`, `Lantern::Middleware::Request` in the
  middleware stack, the mounted engine's beacon route, `config.deploy` and
  which env var it came from, sample rates, ignored record types, the Kamal
  `post-deploy` hook, `app/frontend/lib/lantern.ts`, and whether
  `lantern/rspec` (or `lantern/minitest`) is required by the test helper.
  The last five are informational; it exits non-zero only when the token is
  missing or the ping fails.
- **`lantern:deploy[ref,name,url]`** — POSTs `{deploy, ref, name, url,
  server, timestamp, performer, destination, service, commits}` to
  `{ingest_url}/ingest/deploys`. `deploy` comes from `config.deploy`; aborts
  if that's unset. `ref` defaults to `git rev-parse HEAD` when not passed.
  `performer`/`destination`/`service` come from `KAMAL_PERFORMER`,
  `KAMAL_DESTINATION`, and `KAMAL_SERVICE`. `commits` is up to 50
  `{sha, author, message, at}` objects, newest first, from `git log` — empty
  inside an app container, which has no `.git`, which is why the hook below
  posts from the deployer instead.

## Kamal integration

`bin/rails generate lantern:install` writes `.kamal/hooks/post-deploy` (only
if `config/deploy.yml` already exists). It no-ops when `LANTERN_TOKEN` isn't
set, and never fails a deploy — every network call ends in `|| true`.

The hook runs on the **deployer machine**, not in a container, which is the
whole point: that's where the git history lives and where Kamal exports its
[`KAMAL_*` variables](https://kamal-deploy.org/docs/hooks/overview/)
(`KAMAL_VERSION`, `KAMAL_HOSTS`, `KAMAL_PERFORMER`, `KAMAL_DESTINATION`,
`KAMAL_SERVICE`, `KAMAL_RECORDED_AT`, `KAMAL_COMMAND`, `KAMAL_SUBCOMMAND`,
`KAMAL_ROLE`). With `curl`, `ruby`, and `LANTERN_INGEST_URL` all present it
POSTs directly, twice:

1. `POST $LANTERN_INGEST_URL/ingest/deploys` — `{deploy, ref, name, url,
   server, timestamp, performer, destination, service, commits}`, where
   `commits` is up to 50 `{sha, author, message, at}` objects built from
   `git log -n 50 --format='%H%x1f%an%x1f%s%x1f%cI'` piped through a one-line
   `ruby -rjson -e`. This is what lets the platform show a diff of what
   actually shipped. `name` is `KAMAL_SERVICE_VERSION`; set the optional
   `LANTERN_DEPLOY_URL` to link the marker at a CI run or release page.
2. `POST $LANTERN_INGEST_URL/ingest/kamal` — `{version, hosts, roles,
   performer, destination, service, recorded_at, command, subcommand}`, with
   `hosts` split out of the comma-separated `KAMAL_HOSTS`. The platform uses
   this to know which servers should be reporting.

Without `curl`/`ruby`, or without `LANTERN_INGEST_URL`, it falls back to the
original behaviour — `bin/kamal app exec --primary --reuse "bin/rails
lantern:deploy[$KAMAL_VERSION]"` — which records the same deploy minus the
commit list.

`config.deploy` itself auto-detects `KAMAL_VERSION` with no configuration
needed even without this hook — the hook's job is the deploy marker, the
commit diff, and the server inventory.

## Overhead gate

`bench/overhead.rb` boots the dummy app, drives a request that runs 200
queries with Lantern off and on, and fails (exit 1) if instrumentation
adds more than the budget in `LIMITS`: `p50_ms: 1.5` (CPU time, not wall
— stable under CI load), `per_query_us: 8.0`, `allocations: 3_000`. Run
it with `bundle exec ruby bench/overhead.rb`. Measured on an idle core,
the gem adds ~0.85ms per request (0.4ms fixed, ~2µs per query); the
limits leave headroom for slower CI hosts without letting a real
regression through unnoticed.

## Testing your own app against Lantern

```ruby
# spec/rails_helper.rb
require "lantern/rspec"
```

`lantern_records(type = nil)` flushes and returns buffered records (as
built hashes, filtered to `type` if given) without a real network call —
backed by `Lantern::SpecHelper::MemoryTransport`, swapped in for
`Lantern.reporter` on first use. `require "lantern/rspec"` also includes
`Lantern::SpecHelper` everywhere and adds the block matchers
(`have_lantern_queries`, `have_lantern_n_plus_one`, ...) documented in
[`testing.md`](testing.md); `require "lantern/minitest"` is the Minitest
equivalent. `require "lantern/spec_helper"` on its own, plus your own
`config.include Lantern::SpecHelper`, still works.
