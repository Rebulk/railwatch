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
| `server` | `LANTERN_SERVER` | `Socket.gethostname` | Hostname stamped on every record. |
| `environment` | — | resolved lazily from `Rails.env` | Set `c.environment = "staging"` to report under a name other than the actual Rails env. |

`Lantern.enabled?` delegates to `config.enabled?`, which is `@enabled &&
token.present?` — there is no separate "is configured" check elsewhere.

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
| `buffer_size` | `LANTERN_BUFFER_SIZE` | `5000` | Max buffered records (`Lantern::Buffer`). Oldest is dropped (and counted) when full — never blocks the request thread. |
| `flush_interval` | `LANTERN_FLUSH_INTERVAL` | `2.0` (seconds) | Background thread wakes and flushes on this cadence even if the buffer never fills. |
| `flush_threshold` | `LANTERN_FLUSH_THRESHOLD` | `500` | A `write` that pushes the buffer past this size wakes the thread immediately instead of waiting for the next interval. |
| `connect_timeout` | `LANTERN_CONNECT_TIMEOUT` | `1.0` (seconds) | TCP connect timeout for the ingest POST. |
| `timeout` | `LANTERN_TIMEOUT` | `3.0` (seconds) | Read/write timeout for the ingest POST. |
| `shutdown_timeout` | `LANTERN_SHUTDOWN_TIMEOUT` | `2.0` (seconds) | How long `at_exit` waits for the reporter thread to join before force-flushing anyway. This is the number a Kamal `drain_timeout` needs to clear — see `lantern-cloud/config/deploy.yml`'s own comment on this. |

Delivery (`Lantern::Transport::Http`, `lib/lantern/transport/http.rb`):
gzip NDJSON POST to `{ingest_url}/ingest`, one retry on a raised error or
a 5xx, then the batch is dropped. A 401 marks the transport permanently
unauthorized (no further flush attempts for the process's lifetime); a
402 (quota exceeded) backs off for 60 seconds before the next attempt.
Delivery never raises into app code.

`Lantern.flush` forces an immediate flush (also called by the `command`
patches after a rake task/runner invocation finishes, so short-lived
processes don't lose their last batch to the flush interval). An
unhandled exception bypasses the buffer entirely (`Lantern.record_now` →
`Reporter#write_now`) so a crashing process still reports even if it
never reaches a normal flush.

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

In a clustered, preloaded Puma, add `on_worker_boot { Lantern::Health.start! }`
to `config/puma.rb` — the thread started at boot lives in the master and
does not survive `fork`.

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

## Exception source and request payload

| Attribute | Env var | Default | Meaning |
|---|---|---|---|
| `capture_exception_source` | `LANTERN_CAPTURE_EXCEPTION_SOURCE_CODE` | `true` | Include source snippet lines with each exception's backtrace frames. |
| `capture_exception_locals` | `LANTERN_CAPTURE_EXCEPTION_LOCALS` | `false` | Snapshot the raising frame's local variables (up to 25, values truncated to 200 chars, run through the same filter as request params) onto each exception, like Sentry's locals panel. Installs a `TracePoint(:raise)`; opt in per environment. |
| `capture_request_payload` | `LANTERN_CAPTURE_REQUEST_PAYLOAD` | `false` | Capture (redacted) request params — only for a request that raised, never otherwise. |
| `ignored_exceptions` | `LANTERN_IGNORED_EXCEPTIONS` (comma-separated) | `Configuration::DEFAULT_IGNORED_EXCEPTIONS` | Class names never captured, handled or not. Matched against the error's class *and every named ancestor*, so your own subclass of a listed error is ignored too. Setting the env var replaces the default list; append instead with `c.ignored_exceptions += ["MyApp::Expected"]`. |
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
checks both.

## Inertia: beacon and SSR

`beacon_enabled` (`LANTERN_BEACON`, default `true`) gates
`POST /lantern/beacon`, mounted by the install generator
(`mount Lantern::Engine, at: "/lantern"`) — see `visit` in
`docs/records.md` for the full field list and client batching behavior.
Client setup: call `startLantern()` (generated at
`app/frontend/lib/lantern.ts`) from your Inertia entrypoint.

SSR timing needs no configuration: `Lantern::Patches::Inertia` prepends
`InertiaRails::Renderer#ssr_render` whenever `inertia_rails` SSR is
enabled, and the resulting `ssr_ms` lands on the `request` record's
`inertia` field automatically.

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

## on_unrecoverable

```ruby
Lantern.on_unrecoverable { |error| Rails.error.report(error, handled: true) }
```

Called whenever Lantern rescues one of its own internal errors — a
subscriber block raising, or delivery failing after its retry. With no
callback registered, falls back to `Lantern.debug` (stderr, gated on
`LANTERN_DEBUG`, never `Rails.logger` — so gem-internal failures can
never themselves become `log` records).

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
`keep!`, `sampling?`, `span(name, **attributes) { }`, `ignore { }` / `pause` / `resume` / `paused?` (pause/resume
are the ignore block's building blocks — nestable), `record(type, **fields)`,
`report(error, ...)`, `context(**attrs)`, `user(&block)`, `redact_*`,
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
