# Configuration

Everything below lives on `Railwatch::Configuration`, in
`lib/railwatch/configuration.rb`. Set it via
`Railwatch.configure { |c| ... }` in `config/initializers/railwatch.rb`.
That file is created by
`bin/rails generate railwatch:install`. Most settings have a `RAILWATCH_*`
env var default; the tables below show which. Explicit values set in the
initializer always win over the env var.

## Core

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `enabled` | `RAILWATCH_ENABLED` | `true` | Master switch. `Railwatch.enabled?` is also `false` whenever `token` is blank, so setting only `RAILWATCH_TOKEN` is enough to turn Railwatch on. |
| `token` | `RAILWATCH_TOKEN` | nil | Bearer token for `/ingest`. Required. |
| `ingest_url` | `RAILWATCH_INGEST_URL` | `https://railwatch.rebulk.com` | Platform base URL. Point at a self-hosted instance to override. |
| `allow_http` | `RAILWATCH_ALLOW_HTTP` | `false` | Permit a non-loopback plain HTTP ingest URL. HTTPS is required by default; `localhost`, `127.0.0.1`, and `::1` remain available for local self-hosted development. |
| `deploy` | `RAILWATCH_DEPLOY` | auto-detected (order below), then nil | Version tag stamped on every record and used by `railwatch:deploy`. Full 40-character SHAs are shortened to 12 characters. |
| `detect_deploy` | `RAILWATCH_DETECT_DEPLOY` | `true` | Detect deploys beyond `RAILWATCH_DEPLOY` and `KAMAL_VERSION`. Set false when the app deliberately reports no inferred deploy. |
| `server` | `RAILWATCH_SERVER` | `KAMAL_HOST`, else `Socket.gethostname` | Host stamped on every record. Under Kamal the container hostname carries a per-deploy container id, so the Kamal host wins; it is what the post-deploy hook registers as an expected server, which is what silent-host detection compares against. |
| `environment` | — | resolved lazily from `Rails.env` | Set `c.environment = "staging"` to report under a name other than the actual Rails env. |
| `ignored_request_paths` | `RAILWATCH_IGNORED_REQUEST_PATHS` (comma-separated) | `/up,/railwatch/beacon` | Exact request paths that bypass Railwatch's request execution entirely. In Ruby configuration, `Regexp` entries are also supported. Setting the env var replaces the defaults; append with `c.ignored_request_paths += ["/healthz"]` to keep them. |
| `beacon_allowed_origins` | `RAILWATCH_BEACON_ALLOWED_ORIGINS` | `[]` | Extra origins allowed to post to the beacon beyond the app's own, comma-separated: a full origin (`https://app.example.com`) or a bare host. Like Sentry's allowed domains this bounds abuse rather than authenticating, since an endpoint a browser posts to cannot hold a secret. |
| `beacon_global_rate_limit` | `RAILWATCH_BEACON_GLOBAL_RATE_LIMIT` | `6000` | Beacons accepted per minute across every client, so a rotating address cannot multiply past the per-client limit. 0 disables it. |
| `beacon_rate_limit` | `RAILWATCH_BEACON_RATE_LIMIT` | `120` | Beacon POSTs accepted per client IP per minute before `POST /railwatch/beacon` answers 429. The beacon is unauthenticated and keeps every browser error it is sent, so this is what stops a script from spending the app's event quota. Counted in the app's cache store; `0` turns it off. |

`Railwatch.enabled?` delegates to `config.enabled?`, which is `@enabled &&
token.present?`. There is no separate "is configured" check elsewhere.

Deploy detection stops at the first value found: `RAILWATCH_DEPLOY`,
`KAMAL_VERSION`, `GIT_REV`, `GIT_SHA`, `SOURCE_VERSION`,
`HEROKU_SLUG_COMMIT`, `RENDER_GIT_COMMIT`, the tag from `FLY_IMAGE_REF`,
`VERCEL_GIT_COMMIT_SHA`, `CI_COMMIT_SHA`, `GITHUB_SHA`, a Capistrano
`REVISION` file, then `.git/HEAD`, including loose and packed refs. Git is
never run as a subprocess. An initializer assignment to `config.deploy`
always wins.

The request middleware also recognizes a reporter's own `POST /ingest` when
the configured ingest endpoint runs in the instrumented application. It
bypasses that request only when the method, bearer token, configured
ingest path, and public scheme/host/port all match. An unrelated
application route named `/ingest` remains observable. Rack's normalized
forwarded origin is used, so this works behind a trusted TLS-terminating
proxy with `Forwarded` or `X-Forwarded-*` headers.

## Sampling

`sample` is a hash of rate per execution kind, each `0.0`–`1.0`. The rate
is decided once per execution, not per record, by
`Railwatch::Sampler.decide` in `lib/railwatch/sampler.rb`. A sampled-in
execution ships every child record it buffered. A sampled-out one ships
nothing except an unhandled exception. That exception is governed by its
own `exceptions` rate, decided once and memoized per execution. See
`docs/records.md`'s `exception` section.

| Key | Env var | Default |
|---|---|---|
| `requests` | `RAILWATCH_REQUEST_SAMPLE_RATE` | `1.0` |
| `jobs` | `RAILWATCH_JOB_SAMPLE_RATE` | `1.0` |
| `commands` | `RAILWATCH_COMMAND_SAMPLE_RATE` | `1.0` |
| `scheduled_tasks` | `RAILWATCH_SCHEDULED_TASK_SAMPLE_RATE` | `1.0` |
| `channels` | `RAILWATCH_CHANNEL_SAMPLE_RATE` | `1.0` |
| `exceptions` | `RAILWATCH_EXCEPTION_SAMPLE_RATE` | `1.0` |

Set as a whole hash: `c.sample = { requests: 0.1, jobs: 1.0 }`. Keys you
omit keep their default, since `config.sample_rate` falls back to `1.0`
for an unset kind.

**Per-route overrides** come from `ControllerHelpers`, in
`lib/railwatch/controller_helpers.rb`, which is included into every
controller:

```ruby
class ReportsController < ApplicationController
  railwatch_sample 0.01, only: :index      # before_action wrapping Railwatch.sample(rate)
  railwatch_never_sample only: :health     # before_action wrapping Railwatch.dont_sample
end
```

Both accept the same options as `before_action`: `only:`, `except:`, and
so on. Programmatically, `Railwatch.sample(rate)` re-rolls the current
execution's sampling decision. `Railwatch.dont_sample` forces it off.
`Railwatch.sampling?` reads the current decision.

### Tail-based sampling

Head sampling decides at the *start* of an execution, before anything is
known about it. That is cheap, but it throws away exactly the slow
requests you wanted to see. Tail sampling keeps buffering a
head-sampled-out execution's child records and decides at the *end*, once
the duration and outcome are known.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `tail_sample_slow_ms` | `RAILWATCH_TAIL_SAMPLE_SLOW_MS` | nil (off) | Keep a head-sampled-out execution that ran at least this many milliseconds. |

With it set, or after `Railwatch.keep!`, a head-sampled-out execution
ships its whole tree in three cases: it ran at least
`tail_sample_slow_ms`, `Railwatch.keep!` was called, or it raised an
unhandled exception. The exception case is subject to the `exceptions`
rate. Otherwise the buffered records are discarded at the end and nothing
ships. Such a tree's parent record carries `tail_sampled: true`, so a
tail-kept execution is distinguishable from a head-sampled one.

```ruby
c.sample = { requests: 0.05 }   # keep 5% of requests...
c.tail_sample_slow_ms = 500     # ...plus every request slower than 500ms
Railwatch.keep!                   # keep this one, whatever the head decision was
```

**The trade-off is memory.** With tail sampling on, every sampled-out
execution buffers its child records for its lifetime instead of
discarding them as they happen. Those are queries, logs, cache events,
and so on. The buffer is capped at `Execution::MAX_RECORDS` per
execution, which is 10,000. With it off, the default,
`Execution#recording?` is false for a sampled-out execution and nothing
is built or buffered at all. That is the cheapest path and exactly the
behaviour Railwatch had before. `Railwatch.keep!` can only keep records
made *after* the call unless tail sampling was already on. What was never
buffered can't be resurrected.

### Failure context

Tail sampling buys diagnosability for sampled-out executions with the
memory to buffer *every* one of them. Failure context is the same trade
on a much shorter leash. It keeps a bounded ring of a head-sampled-out
execution's most recent child records, and ships it only if that
execution reports an unhandled exception.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `failure_context` | `RAILWATCH_FAILURE_CONTEXT` | `0` (off) | How many child records a head-sampled-out execution keeps, so an unhandled exception can ship what led up to it. |

```ruby
c.sample = { requests: 0.05 }   # keep 5% of requests...
c.failure_context = 200         # ...and the last 200 records of any that fails
```

With this set, a head-sampled-out request, job attempt, scheduled task,
or command buffers its child records in a ring of that many. If it
reports an unhandled exception, the ring is promoted. The parent, the
exception, and the retained children then all ship together, with
`tail_sampled: true` on the parent. Whether it "reports" one follows the
same policy that decides whether the exception itself ships, i.e. it is
subject to the `exceptions` rate. If it completes normally the ring is
discarded at the end and nothing ships, exactly as before.

Nothing else promotes a ring. The following all leave the sampled-out
execution shipping exactly what it shipped before the ring existed:
`exceptions: 0`, an exception in `ignored_exceptions`, an exception
`Railwatch.report`s as handled or that a controller's `rescue_from`
swallowed, one reported inside `Railwatch.ignore` or between
`Railwatch.pause` and `Railwatch.resume`, and an interactive
`bin/rails runner`'s error. That is nothing, or the lone parent record
that gives an unhandled exception somewhere to hang.
`Railwatch.sample(1.0)` and `Railwatch.keep!` still work from inside the
execution. They now ship the ring's contents with it rather than only
what followed the call.

**The cost** is that a sampled-out execution builds and buffers child
records again. The ring bounds how many are *kept*, not how many are
built. So this is a fraction of what tail sampling costs, but it is not
free, which is why it is off by default. There is no separate byte
limit. Every record type is already truncated where it is built: SQL at
16 KB, exception messages at 4 KB, attributes at 200 bytes. So
`failure_context` records is also the memory bound. Overflow increments
the same dropped-record counter tail sampling uses, reported with the
batch rather than swallowed.

`failure_context` and `tail_sample_slow_ms` are independent. With both
set, tail sampling's larger buffer wins for the whole execution: it keeps
everything, up to `Execution::MAX_RECORDS`, and promotes on duration as
well as on failure.

### Profiling

Sampling and tail sampling say *which* executions ship. Profiling says
which of them also ship a stack profile: where the time inside a slow
request or job actually went. See `docs/records.md`'s `profile` record.

The backend is an optional dependency the app installs itself, because
neither belongs in every Gemfile:

```ruby
gem "vernier"    # Ruby >= 3.2, preferred
gem "stackprof"  # anywhere else
```

With neither installed, `Railwatch::Profiler.available?` is false and every
option below is inert.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `profile_sample` | `RAILWATCH_PROFILE_SAMPLE_RATE` | `0.0` (off) | Fraction of sampled-in executions to profile, rolled once per execution. |
| `profile_slow_ms` | `RAILWATCH_PROFILE_SLOW_MS` | nil (off) | Also ship a profile for any tail-buffering execution that ran at least this many milliseconds. |
| `profile_interval_us` | `RAILWATCH_PROFILE_INTERVAL_US` | `1000` | Sampling interval in microseconds. |
| `profiler` | `RAILWATCH_PROFILER` | nil (auto) | Pin a backend: `vernier` or `stackprof`. Auto prefers vernier when both are installed. |

The two triggers are different bargains:

- **`profile_sample`** decides at the *start*, like head sampling. A
  profiler runs for that fraction of executions and every profile it takes
  is shipped. Cheap and predictable: 1% of requests pay for a profiler,
  99% pay for one `Random.rand`.
- **`profile_slow_ms`** can't know an execution is slow until it is over.
  So it profiles *every* tail-buffering execution from its first line and
  throws away the ones that turn out to be fast. That means it only works
  together with `tail_sample_slow_ms`, since nothing tail-buffers without
  it. It also means **the CPU cost is paid on every execution, not just
  the slow ones**. The profiler's sampling thread runs throughout, and the
  stack table it builds is held for the execution's lifetime. Raise
  `profile_interval_us` if that shows up in your latency. A 5000µs
  interval still resolves a 500ms request perfectly well.

```ruby
c.sample = { requests: 1.0 }
c.tail_sample_slow_ms = 500     # keep every request slower than 500ms...
c.profile_slow_ms = 500         # ...and profile it
c.profile_sample = 0.01         # plus a profile of 1% of everything else
```

Both backends are process-global, so there is one profiler per process.
An execution that starts while another is being profiled simply isn't
profiled. In the Rails `test` env profiling is skipped entirely unless
`profile_sample` is explicitly non-zero. So a suite that inherits the
app's `RAILWATCH_*` environment doesn't start a real profiler on every
example.

## Distributed tracing

Railwatch propagates W3C trace context, so a request that fans out to
other Railwatch-instrumented services shows up as one trace.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `propagate_traces` | `RAILWATCH_PROPAGATE_TRACES` | `true` | Send a `traceparent` header on outgoing Net::HTTP and `Railwatch::Faraday` requests. |
| `trace_propagation_hosts` | `RAILWATCH_TRACE_PROPAGATION_HOSTS` (comma-separated) | nil (every host) | Allow list of hostnames. An entry starting with `.` matches as a suffix (`.services.example.com` matches `api.services.example.com`); anything else must match the host exactly. |

Outgoing: `traceparent: 00-<trace_id>-<execution_id[0,16]>-<flags>`, with
flags `01` when the execution is sampled and `00` when it isn't. A
sampled-out execution still propagates, it just says so. A `traceparent`
the app set itself is never overwritten.

Inbound: the Rack middleware parses `HTTP_TRACEPARENT` and adopts its
trace id and parent id for this execution. A header the W3C spec calls
invalid is ignored and the execution starts its own trace. Invalid means
wrong lengths or non-hex characters, the forbidden version `ff`, an
all-zero trace id, an all-zero parent id, or anything trailing the flags
on version `00`. A future version may append fields after the flags.
Those are accepted and never interpreted as long as they are
dash-delimited, so a newer upstream still links to this service instead
of losing the trace. If the upstream flags say the trace is sampled, the
downstream execution is kept whatever its own head decision was, as with
`Railwatch.keep!` above. Otherwise the trace would have a hole exactly
where this service should be.

## Ignoring whole record types

`ignore` drops a record type before it's ever built. That is cheaper than
filtering after the fact, and the only way to stop the highest-volume
types at the source: `query`, `cache_event`, `log`.

| Value | Env var |
|---|---|
| `:queries` | `RAILWATCH_IGNORE_QUERIES` |
| `:cache_events` | `RAILWATCH_IGNORE_CACHE_EVENTS` |
| `:mail` | `RAILWATCH_IGNORE_MAIL` |
| `:broadcasts` | `RAILWATCH_IGNORE_BROADCASTS` |
| `:notifications` | `RAILWATCH_IGNORE_NOTIFICATIONS` |
| `:outgoing_requests` | `RAILWATCH_IGNORE_OUTGOING_REQUESTS` |
| `:storage_ops` | `RAILWATCH_IGNORE_STORAGE_OPS` |
| `:view_renders` | `RAILWATCH_IGNORE_VIEW_RENDERS` |
| `:logs` | `RAILWATCH_IGNORE_LOGS` |
| `:transactions` | `RAILWATCH_IGNORE_TRANSACTIONS` |
| `:deprecations` | `RAILWATCH_IGNORE_DEPRECATIONS` |
| `:sessions` | `RAILWATCH_IGNORE_SESSIONS` |

```ruby
c.ignore = [:cache_events, :transactions]
```

Setting an unknown type raises `ArgumentError` immediately. This is
validated at assignment, not silently dropped. Note `query` and
`n_plus_one` records both key off `:queries`, and `notification` off
`:notifications`. See `Railwatch::PLURALS` in `lib/railwatch.rb` for the
full singular-to-plural mapping used everywhere ignore/redact/reject
hooks key by plural.

## Redaction

Two built-in filters, both string lists, both merged with what the app
already hides:

| Attribute | Env var | Default |
|---|---|---|
| `redact_headers` | `RAILWATCH_REDACT_HEADERS` (comma-separated) | `Authorization,Cookie,Set-Cookie,Proxy-Authorization,X-CSRF-Token,X-XSRF-TOKEN` |
| `redact_params` | `RAILWATCH_REDACT_PARAMS` (comma-separated) | `password,password_confirmation,authenticity_token,_token` |

`redact_params` is merged with `Rails.application.config.filter_parameters`
at first use, in `Railwatch::Redactor#param_filter`. So anything the app
already scrubs from its own logs is scrubbed here too, with no extra
config. Request params are only captured at all when
`capture_request_payload` is on, and even then only for a request that
raised an exception. See `request` in `docs/records.md`.

Header names containing a credential-shaped segment are always masked as
a safe default. The segments are `api-key`, `access-key`, `private-key`,
`auth`, `bearer`, `credential`, `hmac`, `jwt`, `token`, `secret`, and
`signature`. This holds even when they arrive as concatenated Rack
aliases such as `X-AuthToken`, `X-ApiToken`, `X-AccessToken`,
`X-ClientToken`, `X-SessionToken`, `X-RefreshToken`, `X-SecretKey`,
`X-HmacSignature`, or `X-CSRFToken`. Add application-specific aliases to
`redact_headers`. Ordinary diagnostic headers remain available.

**Per-field redaction blocks** run after a record is built, before it's
buffered. The block receives and can mutate the record hash in place:

```ruby
Railwatch.redact_queries    { |q| q[:sql] = q[:sql].gsub(/email = '[^']+'/, "email = '?'") }
Railwatch.redact_requests   { |r| ... }
Railwatch.redact_exceptions { |e| ... }
Railwatch.redact_cache_events { |c| ... }
Railwatch.redact_commands   { |c| ... }
Railwatch.redact_mail       { |m| ... }
Railwatch.redact_outgoing_requests { |o| ... }
Railwatch.redact_logs       { |l| ... }
```

A redactor that raises drops the record entirely. The error is logged via
`Railwatch.debug`, never raised into app code.

## Rejection

Drop a record entirely based on its content, for the record types that
don't have a matching `redact_*`:

```ruby
Railwatch.reject_queries            { |q| q[:sql].include?("solid_queue") }
Railwatch.reject_cache_events       { |c| ... }
Railwatch.reject_mail               { |m| ... }
Railwatch.reject_notifications      { |n| ... }
Railwatch.reject_broadcasts         { |b| ... }
Railwatch.reject_outgoing_requests  { |r| r[:host] == "127.0.0.1" }
Railwatch.reject_enqueued_jobs      { |j| ... }
Railwatch.reject_logs               { |l| ... }
```

`Railwatch.reject_cache_keys(prefixes)` is a shortcut that appends to
`config.ignored_cache_key_prefixes`. Entries are matched by
`Configuration.match_cache_key?`. A `Regexp` matches as-is. A `String`
starting with `^`, or containing another regex metacharacter, is compiled
as one. A `String` ending in `*` matches as a prefix. Anything else must
match the key exactly.

```ruby
Railwatch.reject_cache_keys %w[session: rack::attack* ^feature_flag_\d+$]
```

A rejector block returning truthy drops the record before it's buffered.
A raising rejector is treated as "don't reject": it fails open and is
logged via `Railwatch.debug`.

## before_ingest

Runs once per batch, right before it's POSTed. This is the last chance to
inspect or drop records as a group. The redact/reject hooks above run
per-record, earlier, at record-build time:

```ruby
Railwatch.before_ingest { |batch| batch.size < 10_000 }   # return false to drop the whole batch
Railwatch.before_ingest { |batch| batch.reject { |r| r[:t] == "log" } }  # return an Array to replace it
```

Multiple hooks chain. Any hook returning `false` drops the batch and
skips remaining hooks. See `Railwatch.run_before_ingest` in
`lib/railwatch.rb`.

## Buffering, flushing, transport

One background thread per process: `Railwatch::Reporter`, in
`lib/railwatch/reporter.rb`. It is re-armed after fork so each Puma
cluster worker / Solid Queue forked worker gets its own. Never touches
the app database.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `buffer_size` | `RAILWATCH_BUFFER_SIZE` | `10000` | Max buffered records (`Railwatch::Buffer`). Oldest is dropped (and counted) when full — never blocks the request thread. Keep it at or above `Execution::MAX_RECORDS` (10,000): a kept execution's whole tree is written here at once when it ends, and a queue smaller than the tree drops the tree's own oldest records first. |
| `buffer_bytes` | `RAILWATCH_BUFFER_BYTES` | `16777216` (16 MiB) | Estimated payload memory the reporter queue may hold. A record count alone does not bound memory: 10,000 records is a few megabytes of ordinary telemetry, or a gigabyte of captured attachments. Oldest records are dropped (and counted) under byte pressure, same as under count pressure. |
| `execution_buffer_bytes` | `RAILWATCH_EXECUTION_BUFFER_BYTES` | `8388608` (8 MiB) | The same ceiling for one execution's buffered tree, before it finishes. A normal execution keeps its earliest records; a failure-context ring keeps its latest. |
| `batch_bytes` | `RAILWATCH_BATCH_BYTES` | `8388608` (8 MiB) | Uncompressed NDJSON bytes in one ingest request. A queue holding more than this is delivered as several batches — the tail is kept for the next flush, not dropped. |
| `backpressure` | `RAILWATCH_BACKPRESSURE` | `true` | Adapt every execution kind's effective sample rate when the reporter buffer reaches its high-water mark or ingest is in retry backoff. |
| `backpressure_high_water` | `RAILWATCH_BACKPRESSURE_HIGH_WATER` | `0.8` | Fraction of either `buffer_size` or `buffer_bytes` that signals pressure. Values must be greater than `0.0` and at most `1.0`; invalid values use the default. |
| `flush_interval` | `RAILWATCH_FLUSH_INTERVAL` | `2.0` (seconds) | Background thread wakes and flushes on this cadence even if the buffer never fills. |
| `flush_threshold` | `RAILWATCH_FLUSH_THRESHOLD` | `500` | A `write` that pushes the buffer past this size wakes the thread immediately instead of waiting for the next interval. |
| `connect_timeout` | `RAILWATCH_CONNECT_TIMEOUT` | `1.0` (seconds) | TCP connect timeout for the ingest POST. |
| `timeout` | `RAILWATCH_TIMEOUT` | `3.0` (seconds) | Read/write timeout for the ingest POST. |
| `shutdown_timeout` | `RAILWATCH_SHUTDOWN_TIMEOUT` | `2.0` (seconds) | Deadline for the reporter thread to deliver retained records during `at_exit`. A deployment drain timeout must be longer than this. |

Delivery is `Railwatch::Transport::Http`, in
`lib/railwatch/transport/http.rb`: a gzip NDJSON POST to
`{ingest_url}/ingest`, with one retry on a raised error or a 5xx within
each delivery attempt. If that still fails, or ingest returns 402, 408,
or 429, the immutable batch and its prior drop count are retained for
retry. Every newly formed batch gets an `X-Railwatch-Batch-Id` UUID. It is
reused for the immediate HTTP retry and every later reporter retry, so
the platform can return the first committed result without inserting the
payload twice. Records written while a request is in flight collect in a
separate bounded buffer, so they never change the retained request's
identity. At most one retained batch plus one live buffer are held in
memory. The reporter retries with jittered exponential backoff, from one
second up to 60 seconds. It does not busy-loop. A 401 marks the transport
permanently unauthorized: no further HTTP attempts for the process's
lifetime. It and other permanent client rejections are reported through
`on_unrecoverable`. Delivery never raises into app code.

HTTPS connections explicitly use OpenSSL `VERIFY_PEER`, and redirects are
not followed. Plain HTTP is refused unless the host is loopback or
`RAILWATCH_ALLOW_HTTP=true`. `railwatch:doctor` reports the policy, and
boot logs a warning when an insecure URL is refused.

On every reporter flush tick, adaptive backpressure doubles a
process-local sample divisor, up to 8x. It does so while either buffer
ceiling is at least 80% full or the retry ladder is active. Clear ticks
halve it back toward 1x. Eight is enough to create room after three
pressured ticks and recovers in three clear ticks. A 16x ceiling would
preserve less telemetry and take longer to recover. The sampler reads the
reporter's Float without locking the request path. The reporter is its
only writer, an ivar assignment is atomic, and one stale read only
affects one probabilistic decision. Set `backpressure` false to keep the
factor at 1. The current value is sent as
`X-Railwatch-Backpressure-Factor` whenever it is greater than 1.

`Railwatch.flush` forces an immediate flush, on the calling thread and
without a time limit, so it is yours to call when you know you want to
wait. Nothing in the gem calls it for you: a short-lived process keeps its
last batch because the engine's `at_exit` runs `Reporter#shutdown`, which
wakes the reporter thread and joins it for `shutdown_timeout`. That is a
bounded wait, which is what a rake task, a runner or a cron job needs --
a receiver that accepts connections and never answers then costs
`shutdown_timeout`, not a timeout ladder per process. An unhandled
exception goes through `Railwatch.record_now` → `Reporter#write_now`,
which enqueues the record and asks for an urgent flush. It never performs
network I/O or a timeout cycle on the application thread. Urgent means
within a quarter of a second, `Reporter::URGENT_FLUSH_DELAY`, not
instantly. During an exception storm every request would otherwise wake
the reporter for a handful of records, and a burst that produced 4,000
records went out as 400 POSTs of ten. A lone exception still ships inside
that window. A storm coalesces into full batches, and a buffer that
crosses `flush_threshold` flushes at once regardless.

During shutdown the reporter immediately attempts any retained batch and
keeps retrying within `shutdown_timeout`. If the deadline expires, the batch
remains accounted for in memory and `on_unrecoverable` receives the unsent
record/drop counts. The buffer is deliberately memory-only: a hard kill or
process exit after that deadline cannot preserve records for the next boot.

## Query and view thresholds

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `slow_query_threshold_ms` | `RAILWATCH_SLOW_QUERY_MS` | `5.0` | Above this, a query's source location is resolved fresh instead of reused from the group cache (see `query` in `docs/records.md`). |
| `n_plus_one_threshold` | `RAILWATCH_N_PLUS_ONE_THRESHOLD` | `5` | Same query group repeating this many times in one execution fires one `n_plus_one` record. |
| `max_view_renders_per_execution` | — (code only) | `20` | Caps stored `view_render` records per execution; all renders still count toward the parent's `view_renders` counter regardless of the cap. |
| `capture_query_explain` | `RAILWATCH_CAPTURE_QUERY_EXPLAIN` | `false` | Attach the adapter's own query plan to slow `SELECT`s as the `query` record's `explain` field. **Its own privacy decision, independent of `capture_sql_values`:** the EXPLAIN runs on the raw statement (a plan of normalized SQL would be meaningless), and a plan can echo literal predicate values — Postgres prints them in `Filter` and `Index Cond` lines. Leave it off if that matters. The EXPLAIN runs on the same connection the query just used, with Railwatch paused so it never records itself, and is rate-limited to one per query shape per process per 10 minutes. Off by default: it doubles the round trips for the queries it fires on. |
| `explain_threshold_ms` | `RAILWATCH_EXPLAIN_THRESHOLD_MS` | `100.0` | Minimum query duration before `capture_query_explain` will explain it. |
| `capture_sql_values` | `RAILWATCH_CAPTURE_SQL_VALUES` | `false` | Send the raw adapter SQL in `query.sql`. Off by default: a `query` record carries the normalized statement shape — placeholders and structure kept, string/numeric/hex/dollar-quoted literals and SQL comments removed — because SQL literals routinely contain email addresses, tokens, and other customer data. Active Record's separate structured binds are never sent in either mode. Normalization follows each dialect's *default* backslash-escaping rule (MySQL escapes, PostgreSQL does not, `E''` does, SQLite does not); a session running `NO_BACKSLASH_ESCAPES` or `standard_conforming_strings = off` is not visible in the notification, and a hand-written statement mixing that mode with a backslash before a quote can leave part of the statement's text in the shape. |

## Process health

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `health_interval` | `RAILWATCH_HEALTH_INTERVAL` | `15.0` | Seconds between `health` records (Puma thread pool, Active Record pool, Solid Queue backlog — see `health` in `docs/records.md`). One background thread per web/worker process; never runs in a console, a rake task, or the `test` env. |

Railwatch re-arms the reporter, sampler, and profiler after `fork`. It
uses one `ActiveSupport::ForkTracker` callback, Rails' own `Process._fork`
hook. So clustered Puma workers and forked Solid Queue workers each get a
fresh buffer, transport policy state, process record, health thread, and
profiler slot. The child never flushes records or drop accounting
inherited from its parent, and no `on_worker_boot` configuration is
needed.

The `process` record is written from `config.after_initialize`, after the
app's own initializers, so `boot_seconds` covers them. A Puma master that
preloads the app runs those initializers too. So it writes its own
`process` record and starts its own reporter, health, and session threads
before forking. Puma prints "Detected N Thread(s) started in app boot"
for them. That is advisory: the threads it is warning about are exactly
the ones the fork callback replaces in every worker. The Rake and
`bin/rails runner` patches are installed from the engine's `rake_tasks`
and `runner` hooks, which only a rake or runner process fires. So a web
or worker boot does not require rake or railties' runner command.

A numeric `RAILWATCH_*` value that is not a number, such as
`RAILWATCH_BUFFER_SIZE=12px`, falls back to the default documented in the
tables above rather than being coerced to `0`.

### Release health

`session` records count sessions per deploy, which is what the platform's
crash-free session and crash-free user rates are computed from. The
`deploy` on every record *is* the release.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `track_sessions` | `RAILWATCH_TRACK_SESSIONS` | `true` | Master switch for both session sources. Off means the request middleware does nothing extra and no flusher thread is started. |
| `session_flush_interval` | `RAILWATCH_SESSION_FLUSH_INTERVAL` | `60.0` | Seconds between server-session flushes. One background thread per web process, re-armed after `fork` exactly like the health sampler, and flushed once more on shutdown. |
| `session_timeout` | `RAILWATCH_SESSION_TIMEOUT` | `1800.0` | Seconds a server session may sit idle before it ships with `ended` and is forgotten. |

There are two sources, and they meet on the same id:

- **The browser client** is `app/frontend/lib/railwatch.ts`, installed by
  `railwatch:install`. It mints one id per tab in `sessionStorage` and
  mirrors it into a `railwatch_session` cookie. It rides along on the
  beacon flushes the client already sends for visits, so this costs no
  extra requests. This is the primary source for a web app, and it is
  what makes session duration mean "how long the tab was open".
- **The request middleware** aggregates, in memory, every request that
  either resolves a user or carries that cookie or an
  `X-Railwatch-Session` header. It is the only source for an API-only
  app. It is also the only one that can see an unhandled exception, which
  is what makes a session `crashed`.

When a browser session's requests carry the cookie both sources produce
records under the same id and the platform dedupes them.

## Vendor noise defaults

Framework/vendor activity excluded by default so a fresh install isn't
dominated by Rails' own housekeeping:

| Attribute | Env var | Default | Affects |
|---|---|---|---|
| `capture_default_vendor_commands` | `RAILWATCH_CAPTURE_DEFAULT_VENDOR_COMMANDS` | `false` | `Configuration::DEFAULT_VENDOR_COMMANDS`: `db:migrate`, `db:schema:load`, `db:schema:dump`, `db:seed`, `db:prepare`, `assets:precompile`, `assets:clobber`, `tmp:cache:clear`, `log:clear`. |
| `capture_default_vendor_cache_keys` | `RAILWATCH_CAPTURE_DEFAULT_VENDOR_CACHE_KEYS` | `false` | `Configuration::DEFAULT_VENDOR_CACHE_KEYS`: `rack::attack`, `flipper`, `solid_cable`, `active_storage`, `migration_`, `schema_cache` prefixes. |
| `capture_framework_events` | `RAILWATCH_CAPTURE_FRAMEWORK_EVENTS` | `false` | Rails 8.1 structured `Rails.event` events under `action_controller.*`, `active_record.*`, etc. — already redundant with the `request`/`job_attempt` records, so off by default. |

`ignored_cache_key_prefixes` is separate from these vendor defaults and
always applies. It is code only, with no env var; use
`Railwatch.reject_cache_keys` above.

## Interactive sessions: console and runner

An engineer poking at production from a shell is not the application failing.
Sentry never hooked `bin/rails console` at all, and Railwatch keeps that
behaviour, while making sure a deployed script still reports.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `capture_console` | `RAILWATCH_CAPTURE_CONSOLE` | `false` | When `false`, a `bin/rails console` process captures nothing — no exceptions, queries, or logs — starts no reporter/health/session thread, and sends no `process` or `health` record. Set it to `true` for the rare "trace what I'm about to do in here" session. Detected from `Rails::Console`, which railties defines before the app boots (`lib/railwatch/console.rb`). |
| `interactive_runner_paths` | `RAILWATCH_INTERACTIVE_RUNNER_PATHS` (comma-separated) | `Configuration::DEFAULT_INTERACTIVE_RUNNER_PATHS`: `/tmp/`, `/var/tmp/` | Scratch roots. A `bin/rails runner` given a `.rb` file under one of these is treated as hand-written (typed in a shell inside a container) rather than deployed. |

`bin/rails runner` is classified by **where the code came from**, which is
the only thing that separates a typo from a cron job:

| Invocation | Treated as | Result |
|---|---|---|
| `rails runner -` | interactive | `command` record with `interactive: true`, no exception reported |
| `rails runner 'Some.code'` | interactive | same |
| `rails runner /tmp/probe.rb` | interactive | same (a `.rb` file under `interactive_runner_paths`) |
| `rails runner script/nightly.rb` | deployed | `command` record and the exception, as before |

An interactive run is still recorded. The `command` record ships with its
`exit_code`, duration, and `exception_preview`, so you can see that
someone ran something and that it died. It just doesn't open an issue.
Rake tasks and Solid Queue jobs are never interactive.

## Exception source and request payload

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `capture_exception_source` | `RAILWATCH_CAPTURE_EXCEPTION_SOURCE_CODE` | `true` | Send source snippet lines surrounding each in-application exception frame to Railwatch Cloud. This is on by default for crash context; disable it when source disclosure is outside the application's telemetry policy. |
| `capture_exception_locals` | `RAILWATCH_CAPTURE_EXCEPTION_LOCALS` | `false` | Snapshot the raising frame's local variables (up to 25, values truncated to 200 chars, run through the same filter as request params) onto each exception, like Sentry's locals panel. Installs a `TracePoint(:raise)`; opt in per environment. |
| `capture_request_payload` | `RAILWATCH_CAPTURE_REQUEST_PAYLOAD` | `false` | Capture (redacted) request params — only for a request that raised, never otherwise. |
| `capture_job_arguments` | `RAILWATCH_CAPTURE_JOB_ARGUMENTS` | `false` | Add the job's real arguments (`job.serialize["arguments"]`) to each `job_attempt`/`scheduled_task` record, capped at 8 KiB of JSON. Hash arguments run through the same filter as request params. Off by default because job arguments routinely carry PII; `arguments_preview` (argument *shapes* only) is always on regardless. |
| `capture_job_retry_errors` | `RAILWATCH_CAPTURE_JOB_RETRY_ERRORS` | `false` | Capture the exception that caused an Active Job `retry_on` retry as handled, warning-level exception telemetry. Off by default because retries are usually expected and capturing them can flood the issues list. The retry log line is recorded either way. |
| `capture_response_body_on_error` | `RAILWATCH_CAPTURE_RESPONSE_BODY_ON_ERROR` | `false` | Add the first 4 KiB of the response body to an `outgoing_request` record when the response was an error (status ≥ 400, or the call raised). A JSON object body is filtered like request params and re-serialized; anything else is stored as it arrived. Off by default — a third party's error body is arbitrary data you didn't write. |
| `ignored_exceptions` | `RAILWATCH_IGNORED_EXCEPTIONS` (comma-separated) | `Configuration::DEFAULT_IGNORED_EXCEPTIONS` | Class names never captured, handled or not. The default list is Sentry's Rails-relevant exclusions plus `SignalException` (a SIGTERM/SIGINT ending a process is a shutdown, not an error; rake and runner also close their command record with exit code 128+signal instead of reporting). Matched against the error's class *and every named ancestor*, so your own subclass of a listed error is ignored too. Setting the env var replaces the default list; append instead with `c.ignored_exceptions += ["MyApp::Expected"]`. |
| `capture_rescued_exceptions` | `RAILWATCH_CAPTURE_RESCUED_EXCEPTIONS` | `true` | Capture exceptions a controller swallows with `rescue_from` (Rails' `rescue_from_callback.action_controller` notification) as `handled: true`, `severity: :warning`, `source: "action_controller.rescue_from"`. Sentry calls this `report_rescued_exceptions`. |

`DEFAULT_IGNORED_EXCEPTIONS` is the Rails-relevant subset of Sentry's own
`excluded_exceptions` defaults, routine 4xx plumbing rather than
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
to `Rails.error` in the first place. `ActiveRecord::RecordNotFound` → 404
is one such. So several of these are belt-and-braces for the paths that
*do* reach Railwatch: jobs, `Railwatch.report`, and `rescue_from`.

## Logging

| Attribute | Env var | Default |
|---|---|---|
| `log_level` | `RAILWATCH_LOG_LEVEL` | `:info` |

Only `Rails.logger` lines at or above this level become `log` records.
Rails' own per-request/job noise is filtered regardless of level, since
the `request`/`job_attempt` records already carry that information. That
noise is `"Started GET"`, `"Processing by"`, `"Rendered"`, etc.
Message text is otherwise shipped as written and is not parsed for embedded
secrets. Keep secrets out of logs, use `Railwatch.redact_logs` for an
application-specific scrub, or disable log records with
`RAILWATCH_IGNORE_LOGS=true`.

## User resolution

```ruby
c.user { |user| { id: user.id, name: user.name, email: user.email } }
```

The default, with no block set, reads `Current.user` if defined. That is
the authentication-zero / Rails 8 auth generator convention. Otherwise it
reads Warden's `env["warden"].user`, which is Devise. The resolved id is
memoized per user per process-hour so a `user` record ships once, not
once per request. See `Railwatch::Subscribers::Users` and
`docs/records.md`'s `user` section.

Ids are tenant-scoped: with a tenant bound, `1` is recorded as `acme:1`. It
does not matter whether the tenant binds before or after the user is
resolved. An app that resolves the user in one `before_action` and the
tenant in the next still gets `acme:1`, on the records already buffered
as well as the ones after. Return an already-scoped value from the block
and it is left alone. That might be an external id, or
`"#{org.slug}:#{user.id}"`.

A request resolves its user at the end, but a job enqueued mid-action
needs one immediately. So `JobTracing#serialize` resolves the enqueuing
execution's user and tenant and puts those two identifier strings into
the Active Job payload, as `railwatch_user`/`railwatch_tenant`. The worker
restores them before the attempt records anything. So a `job_attempt` and
every child record under it are attributed to the person whose request
enqueued the job, rather than to a worker process that has no signed-in
user. A job that enqueues a job passes the same identity on. Nothing but
the two strings crosses the queue; no model is serialized or hydrated.
Payloads carry the keys only when there is something to carry. A payload
without them falls back to local resolution, so a queue drained across a
deploy keeps working. See `docs/records.md`'s `job_attempt` section for
retries, scheduled jobs, and the cardinality note.

```ruby
c.beacon_user { |request| Session.find_by(id: request.cookie_jar.signed[:session_token])&.user }
```

Who is behind a browser beacon: visits, browser sessions, JavaScript
errors. The beacon is handled by the gem's engine controller, outside
your `ApplicationController`. So an app that authenticates in a
`before_action`, such as a signed session cookie looked up per request,
has not run it when the beacon arrives, and `Current.user` is nil there.
Give Railwatch the same lookup; it hands the result to the `user` block
above. Not needed when `Current.user` is set in middleware or by Warden.

## Tenant / context

```ruby
Railwatch.context(tenant: org.slug, plan: org.plan)
```

Writes through to `ActiveSupport::ExecutionContext`,
`Rails.error.set_context`, and `Rails.event.set_context` in one call, via
`Railwatch::Context.set` in `lib/railwatch/context.rb`. So context set for
Railwatch also shows up anywhere else Rails' own context stores are read.
It is serialized onto every record's `context` field, through the same
`ActiveSupport::ParameterFilter` that redacts request params. That filter
is `c.redact_params` plus Rails' `config.filter_parameters`. So a token or
password put in context is `[FILTERED]` on the wire, not written verbatim
onto every record made while it was set. A context over 64KB is rebuilt
smaller rather than cut. Whole values are kept while they fit, an
oversized string value ends with `[TRUNCATED]`, anything that still does
not fit is dropped, and the result carries `"_railwatch_truncated": true`.
It is always parseable JSON. The previous behaviour sliced the encoded
string at 64KB, which produced a fragment the platform could not read at
all. `tenant` specifically is auto-detected with no explicit
`Railwatch.context` call needed when the app uses `activerecord-tenanted`,
via `ActiveRecord::Base.current_tenant`, or `TenantRecord`, via
`TenantRecord.current_tenant`. `Context.current_tenant` checks both. The
tenant is re-read while it is still nil. So a tenant bound *inside* the
execution still lands on the request/job record and every child made
after the bind. activerecord-tenanted's `TenantSelector` middleware sits
under Railwatch's, as do `around_action`s and a job's `with_tenant` block.
Records made before the bind keep `tenant: nil`. A `before_action` that
loads the user, say, is one such.

## Inertia: beacon and SSR

`beacon_enabled`, env var `RAILWATCH_BEACON`, default `true`, gates
`POST /railwatch/beacon`. The install generator mounts that route with
`mount Railwatch::Engine, at: "/railwatch"`. See `visit` and `exception`
in `docs/records.md` for the full field lists and client batching
behavior. The same beacon carries visit timing, Core Web Vitals, browser
sessions, and every JavaScript error the page throws. Turning
`beacon_enabled` off turns off all four. The endpoint takes no
credential, so it is throttled per client IP by `beacon_rate_limit`,
default 120 a minute, `0` to disable. A client past the limit gets a 429
with `Retry-After` and nothing from that POST is recorded. Client setup:
call `startRailwatch()` from your Inertia entrypoint. It is generated at
`app/frontend/lib/railwatch.ts`.

`startRailwatch` takes three optional settings, none of which has a
server-side equivalent. They are decisions about the browser the code is
running in:

```ts
startRailwatch({
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
  // posts to /railwatch/beacon, outside that scoping, so the server cannot
  // resolve the tenant itself. Read on every flush. A tenant the server
  // does resolve (`Context.current_tenant`) always wins.
  tenant: () => /^\/orgs\/([^/]+)/.exec(location.pathname)?.[1],
})
```

The same file exports two more things. `railwatchRootOptions()` returns
React 19's `onCaughtError`/`onUncaughtError` root options, used as
`createRoot(el, railwatchRootOptions())`. That is what reports an error a
boundary caught, since React only sends those to `console.error` outside
a development build. `reportError(error, context?)` reports an error the
app caught itself, and is how a React 18 boundary's `componentDidCatch`
does the same thing. See
[`docs/replacing-sentry.md`](replacing-sentry.md) for what is and is not
captured versus `@sentry/react`.

SSR timing needs no configuration. `Railwatch::Patches::Inertia` prepends
`InertiaRails::Renderer#ssr_render` whenever `inertia_rails` SSR is
enabled. The resulting `ssr_ms` lands on the `request` record's
`inertia` field automatically.

## Manual reporting and instrumentation

```ruby
Railwatch.report(error, handled: true, context: { order_id: order.id })
Railwatch.ignore { ExpensiveSync.run }          # pause recording for the block, restored after
Railwatch.instrument_outgoing(:get, url) { http_client.get(url) }  # for HTTP clients without a dedicated patch
```

`Railwatch.report` defaults `severity` to `:warning` when `handled: true`,
`:error` otherwise, and tags `source: "railwatch.manual"`.
`Railwatch.instrument_outgoing` records an `outgoing_request` only if the
block's return value responds to `#status`. It is for Faraday-alike
client objects that aren't Net::HTTP and don't already go through
`Railwatch::Faraday` middleware.

### Fingerprinting

How an exception is bucketed into an issue. The default is class + top
in-app frame + normalized message. See
[`docs/records.md`](records.md)'s `exception` section for what
normalization removes. Three ways to override it, in precedence order:

```ruby
# 1. Per call, when you already know the bucket.
Railwatch.report(error, fingerprint: [ "payments", gateway.name ])

# 2. On your own error class, so every raise site agrees.
class PaymentError < StandardError
  def railwatch_fingerprint = [ "payments", gateway ]
end

# 3. Globally, in an initializer (one block; Sentry's before_send fingerprint).
Railwatch.fingerprint do |error, default|
  error.is_a?(Faraday::Error) ? [ "upstream", error.response_status, :default ] : nil
end
```

The block is called with the error and `default`. `default` is the Array
of parts Railwatch would have hashed:
`[class, file, line, normalized message]`. It returns an Array of
strings/symbols/numbers. The literal `:default` splices those default
parts in wherever you put it, like Sentry's `{{ default }}`. Parts are
stringified, empty ones dropped, and the result capped at 10 parts of 200
chars. Returning nil or an empty Array, or raising, falls back to the
default, so a bad resolver can never lose an exception. Every `exception`
record carries the parts it was hashed on, as `fingerprint`, and where
they came from, as `fingerprint_source`. An attachment filed against the
error with `Railwatch.attach(..., exception:)` follows the same rule, so
it lands on the same issue.

### Attachments

Ship an arbitrary blob as its own `attachment` record, like Sentry's
`Sentry.add_attachment`. That might be the payload that failed to parse,
a rendered PDF, or the webhook body a customer swears they sent:

```ruby
Railwatch.attach("payload.json", request.raw_post)                  # a String
Railwatch.attach("invoice.pdf", Rails.root.join("tmp/invoice.pdf")) # a Pathname, or any IO
Railwatch.attach("payload.json", body, content_type: "text/plain")  # override the guessed type
Railwatch.attach("payload.json", body, exception: error)            # file it against an issue
Railwatch.report(error, attachments: { "payload.json" => body })    # capture + attach in one call
```

`content_type` defaults to whatever Marcel makes of the name's extension,
or `application/octet-stream` if it can't tell. Passing `exception:` sets
the record's `exception_group_hash` to the same group hash the
`exception` record is filed under, so the platform shows the attachment
on that issue. An attachment made inside a recording execution belongs to
it. Made with nothing executing, it ships standalone. Returns nil and
records nothing when Railwatch is disabled or the payload is empty.

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `max_attachment_bytes` | `RAILWATCH_MAX_ATTACHMENT_BYTES` | `1048576` (1 MiB) | Payloads longer than this are cut to the cap and the record is flagged `truncated: true`. Files and IOs are read with at most cap + 1 bytes rather than read whole and then sliced. `bytes` on the record is always the stored size. Data is gzipped and base64-encoded on the wire, so the cap is on the *original* bytes, not what ships. |

## on_unrecoverable

```ruby
Railwatch.on_unrecoverable { |error| Rails.error.report(error, handled: true) }
```

Called whenever Railwatch rescues one of its own internal errors, ingest
permanently rejects a batch, or shutdown expires with retained records
that could not be sent. Retryable delivery failures stay buffered and do
not fire the callback on every attempt. With no callback registered, a
recovered internal error falls back to `Railwatch.debug`, gated on
`RAILWATCH_DEBUG` — the gem carried on and there is nothing to do about it.

**Lost records are different, and are reported by default.** A batch
dropped after its retry ladder, one the receiver permanently refused, or
records still unsent when the bounded shutdown ran out of time each print
one `[railwatch]` stderr line. Telemetry that vanishes silently looks
exactly like having nothing to report, and a short-lived process — a rake
task, a `rails runner`, a cron job — gets one bounded shutdown and no
second chance to mention it.

Two ways out, and the line names both. A registered `on_unrecoverable`
always wins, which is how an app routes the loss somewhere better
(`Rails.error.report`). Or set `warn_on_data_loss = false`
(`RAILWATCH_WARN_ON_DATA_LOSS=false`) and the gem goes back to saying
nothing.

Either way it is stderr, never `Rails.logger`, so gem-internal failures can
never themselves become `log` records.

## Faraday

Opt in per connection. This is only needed for a non-default Faraday
adapter; the default adapter is Net::HTTP, already covered globally:

```ruby
Faraday.new(url) { |f| f.use Railwatch::Faraday }
```

## debug

| Attribute | Env var | Default |
|---|---|---|
| `debug` | `RAILWATCH_DEBUG` | `false` |

Internal diagnostics to stderr, via `warn`, prefixed `[railwatch]`. This
is deliberately not `Rails.logger`, so turning this on can't create a
feedback loop of `log` records about Railwatch's own failures.

## Public facade — full method list

Mirrors Laravel Nightwatch's facade shape. All on the `Railwatch` module,
in `lib/railwatch.rb`, unless noted:

`configure`, `config`, `enabled?`, `sample(rate)`, `dont_sample`,
`keep!`, `sampling?`, `span(name, **attributes) { }`, `ignore { }` /
`pause` / `resume` / `paused?`, `record(type, **fields)`,
`report(error, ..., attachments: {}, fingerprint: [])`, `attach(name, data, ...)`, `context(**attrs)`, `user(&block)`,
`fingerprint(&block)`, `redact_*`,
`reject_*`, `reject_cache_keys`, `before_ingest`, `on_unrecoverable`,
`instrument_outgoing`, `flush`, `debug { }`. `pause`/`resume` are the
ignore block's building blocks, and are nestable.

## Embedded mode

```ruby
c.transport = :local        # RAILWATCH_TRANSPORT; default "http"
c.issue_prefix = "SHOP"     # RAILWATCH_ISSUE_PREFIX; default from the app name
c.repository_url = "..."    # RAILWATCH_REPOSITORY_URL
c.retention_days = 7        # RAILWATCH_RETENTION_DAYS
c.http_basic_auth_enabled = true      # RAILWATCH_HTTP_BASIC_AUTH_ENABLED; on and closed until credentials exist
c.http_basic_auth_user = "ops"        # RAILWATCH_HTTP_BASIC_AUTH_USER, or credentials railwatch.http_basic_auth_user
c.http_basic_auth_password = "..."    # RAILWATCH_HTTP_BASIC_AUTH_PASSWORD, or credentials railwatch.http_basic_auth_password
c.base_controller_class = "AdminController"  # RAILWATCH_BASE_CONTROLLER_CLASS; default ActionController::Base
c.dashboard_open = false              # RAILWATCH_DASHBOARD_OPEN; public on purpose
c.dashboard_user = ->(request) { { id:, name:, email: } or nil }
```

With `transport = :local` the reporter writes each batch into the app's
own `railwatch_telemetry` database instead of POSTing it, and the engine
serves the dashboard at its mount. `enabled?` no longer needs a token.
The others only matter in that mode. The dashboard is behind HTTP Basic
by default and answers 401 until `bin/rails
railwatch:authentication:configure` has written credentials; a host with
its own admin auth turns Basic off and sets `base_controller_class` or a
routes constraint. Full walkthrough: [Embedded mode](embedded.md).

## Rake tasks

Ship with the gem via Rails::Engine's default `lib/tasks` convention, in
`lib/tasks/railwatch_tasks.rake`:

- **`railwatch:status`** pings `{ingest_url}/ingest/ping` with the
  configured token. It aborts if `RAILWATCH_TOKEN` is unset or the ping
  fails.
- **`railwatch:doctor`** prints a ✓/✗ checklist of the whole install:
  token, ingest URL, `GET /ingest/ping`, `Railwatch::Middleware::Request`
  in the middleware stack, the mounted engine's beacon route,
  `config.deploy` and its environment, `REVISION`, Git, or initializer
  source, sample rates, ignored record types, the Kamal `post-deploy`
  hook, `app/frontend/lib/railwatch.ts`, and whether `railwatch/rspec` or
  `railwatch/minitest` is required by the test helper. The last five are
  informational. It exits non-zero only when the token is missing or the
  ping fails.
- **`railwatch:deploy[ref,name,url]`** POSTs `{deploy, ref, name, url,
  server, timestamp, performer, destination, service, commits}` to
  `{ingest_url}/ingest/deploys`. `deploy` comes from `config.deploy`. It
  aborts if that's unset. `ref` defaults to `git rev-parse HEAD` when not
  passed. `performer`/`destination`/`service` come from `KAMAL_PERFORMER`,
  `KAMAL_DESTINATION`, and `KAMAL_SERVICE`. `commits` is up to 50
  `{sha, author, message, at}` objects, newest first, from `git log`. It
  is empty inside an app container, which has no `.git`. That is why the
  hook below posts from the deployer instead.

## Kamal integration

`bin/rails generate railwatch:install` writes `.kamal/hooks/post-deploy`,
but only if `config/deploy.yml` already exists. It no-ops when
`RAILWATCH_TOKEN` isn't set, and never fails a deploy. Every network call
ends in `|| true`.

The hook runs on the **deployer machine**, not in a container, which is
the whole point. That's where the git history lives and where Kamal
exports its
[`KAMAL_*` variables](https://kamal-deploy.org/docs/hooks/overview/).
Those are `KAMAL_VERSION`, `KAMAL_HOSTS`, `KAMAL_PERFORMER`,
`KAMAL_DESTINATION`, `KAMAL_SERVICE`, `KAMAL_RECORDED_AT`,
`KAMAL_COMMAND`, `KAMAL_SUBCOMMAND`, `KAMAL_ROLE`. With `curl`, `ruby`,
and `RAILWATCH_INGEST_URL` all present it POSTs directly, twice:

1. `POST $RAILWATCH_INGEST_URL/ingest/deploys` with `{deploy, ref, name,
   url, server, timestamp, performer, destination, service, commits}`.
   `commits` is up to 50 `{sha, author, message, at}` objects built from
   `git log -n 50 --format='%H%x1f%an%x1f%s%x1f%cI'` piped through a
   one-line `ruby -rjson -e`. This is what lets the platform show a diff
   of what actually shipped. `name` is `KAMAL_SERVICE_VERSION`. Set the
   optional `RAILWATCH_DEPLOY_URL` to link the marker at a CI run or
   release page.
2. `POST $RAILWATCH_INGEST_URL/ingest/kamal` with `{version, hosts, roles,
   performer, destination, service, recorded_at, command, subcommand}`.
   `hosts` is split out of the comma-separated `KAMAL_HOSTS`. The platform
   uses this to know which servers should be reporting.

Without `curl`/`ruby`, or without `RAILWATCH_INGEST_URL`, it falls back to
the original behaviour: `bin/kamal app exec --primary --reuse "bin/rails
railwatch:deploy[$KAMAL_VERSION]"`. That records the same deploy minus the
commit list.

`config.deploy` itself auto-detects `KAMAL_VERSION`, and the other
release sources listed under Core, with no configuration needed even
without this hook. The hook's job is the deploy marker, the commit diff,
and the server inventory.

## Overhead gate

`bench/overhead.rb` boots the dummy app on SQLite and drives three
request shapes: no queries; 20 uncached queries; the N+1 widgets page. It
runs them with Railwatch's subscribers unsubscribed and then subscribed,
alternating every batch. It fails with exit 1 if instrumentation adds
more than the per-shape budget in `LIMITS`. That budget is CPU time on
the request thread, not wall, which is stable under CI load, plus an
allocation count. It also fails if the log capture has made
`Rails.logger.debug?` true. Run it with `bundle exec ruby
bench/overhead.rb`. Measured on a shared box the gem adds ~0.4ms fixed
per request plus 40–80µs per real query. The limits leave headroom for
slower CI hosts without letting a real regression through unnoticed. The
numbers and how they were taken are in [`docs/faq.md`](faq.md).

## Testing your own app against Railwatch

```ruby
# spec/rails_helper.rb
require "railwatch/rspec"
```

`railwatch_records(type = nil)` flushes and returns buffered records
without a real network call. They come back as built hashes, filtered to
`type` if given. It is backed by `Railwatch::SpecHelper::MemoryTransport`,
swapped in for `Railwatch.reporter` on first use.
`require "railwatch/rspec"` also includes `Railwatch::SpecHelper`
everywhere and adds the block matchers documented in
[`testing.md`](testing.md), such as `have_railwatch_queries` and
`have_railwatch_n_plus_one`. `require "railwatch/minitest"` is the
Minitest equivalent. `require "railwatch/spec_helper"` on its own, plus
your own `config.include Railwatch::SpecHelper`, still works.
