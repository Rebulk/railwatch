# Coming from Laravel Nightwatch

Railwatch is the same product shape for Rails: one package instruments the
framework end to end, records are grouped under the execution that
produced them, and a hosted platform turns them into routes, jobs,
queries, issues, and alerts. If you know Nightwatch, you already know
how to read Railwatch — this page maps the vocabulary and points out the
three places the Rails answer is genuinely different.

Railwatch is an independent product and is not affiliated with Laravel or
Laravel Nightwatch.

## The architecture difference: no agent

Nightwatch needs `nightwatch:agent` because PHP-FPM has no long-lived
process to batch from: the app writes records over a socket and a
separate daemon POSTs them.

Puma and Solid Queue workers *are* long-lived, so Railwatch skips that
tier. A single reporter thread per process holds a bounded buffer
(default 5,000 records, oldest dropped and counted), and gzip-NDJSON
POSTs batches to the platform every 2 seconds or every 500 records. There
is no daemon to install, supervise, or forget to restart, and nothing
between the app and the ingest URL.

The thread is re-armed after `fork`, so clustered Puma workers and
forked Solid Queue workers each get their own with no `on_worker_boot`
hook to write.

## Records

Nightwatch's types, and what they're called here:

| Nightwatch | Railwatch | Notes |
|---|---|---|
| `request` | `request` | Plus `controller`/`action`, `format`, `queue_time` from `X-Request-Start`, `view_runtime`/`db_runtime`, `redirect_to`, `halted_callback`, `unpermitted_parameters`, `rate_limited`, and an `inertia` block (component, version, partial reload, prop bytes, SSR ms). |
| `command` | `command` | Rake tasks and `bin/rails runner`, not Artisan — Rails has no command bus. Task prerequisites nest inside the top-level command rather than opening their own. |
| `job-attempt` | `job_attempt` | Active Job level, so the adapter (Solid Queue, Sidekiq, ...) doesn't matter. Adds `attempt`, `queue_latency`, `concurrency_key`, `priority`, and a `"released"` status for a `retry_on` that caught internally. |
| `scheduled-task` | `scheduled_task` | Solid Queue recurring tasks from `config/recurring.yml`, detected from `SolidQueue::RecurringExecution`. Carries `task_key`, `schedule`, and `drift`. |
| — | `channel_action` | One Action Cable action parent with its SQL, logs, broadcasts/transmits, and exception in the same trace. |
| `query` | `query` | Normalized per adapter, with source `file:line`. Cached queries are counted, not stored. |
| — | `n_plus_one` | Derived in-process: the same query group repeating `n_plus_one_threshold` times (default 5) in one execution. |
| — | `transaction` | Duration, outcome, statement count. |
| `exception` | `exception` | Grouped by class + top app frame + normalized message, overridable per class, per call, or globally. |
| `cache-event` | `cache_event` | Same hit/miss/write/delete shape, over Active Support::Cache. |
| `mail` | `mail` | Render ms vs deliver ms, recipient counts, delivery method. |
| `notification` | `notification` | The `noticed` gem, if loaded. Laravel's channel system has no Rails equivalent. |
| — | `broadcast` | Action Cable `broadcast`/`transmit` — the closest thing Rails has to Laravel's push channels. |
| `outgoing-request` | `outgoing_request` | One `Net::HTTP` prepend covers Faraday's default adapter, HTTParty, RestClient, and `ruby-llm`; `Railwatch::Faraday` is the Guzzle-middleware equivalent for other adapters. |
| `queued-job` | `enqueued_job` | The enqueue side, in the execution that enqueued it. |
| `log` | `log` | Lines at or above `log_level`, plus Rails 8.1 structured `Rails.event` events. |
| `user` | `user` | Resolved once per user per process-hour, not once per request. |
| deployment (`nightwatch:deploy`) | `Deploy` on the platform | Posted by `railwatch:deploy` or the Kamal `post-deploy` hook, with up to 50 commits so the platform can diff what shipped. |
| request `stages` | parent `stages` | Same idea, Rails boundaries: `middleware_before`, `action`, `render`, `middleware_after`, `body`. Laravel's `bootstrap` has no equivalent in a warm process — Railwatch reports boot time once per process as a `process` record instead. |

And the types with no Nightwatch counterpart at all: `storage_op` (Active
Storage), `view_render`, `span` (your own timed blocks), `attachment`,
`deprecation`, `visit` (Inertia page visits from the browser),
`session` (release health), `process`, `health` (Puma pool, Active Record
pool, Solid Queue backlog), and `profile` (sampled stack profiles).

Field-by-field detail for all 26 is in [`records.md`](records.md).

## What "execution" means

Exactly what it means in Nightwatch, with one more parent type. An
execution is a **request**, a **job attempt**, a **scheduled task run**,
or a **command**. Every other record is a child of one: it carries
`execution_id`, `execution_source`, `execution_preview` (the human
label, e.g. `"GET /posts"`), and `execution_stage` (which lifecycle stage
it happened in).

`trace_id` is the wider unit. It is shared by a request and every job
that request enqueued, so async work traces back to what started it, and
it is propagated across services as a W3C `traceparent` on outgoing HTTP
— an inbound `traceparent` is adopted, so a trace spans services rather
than stopping at the process boundary.

Practically: on the platform you never look at a query in isolation. You
open the request, and the query is in its waterfall with everything else
that execution did.

## Sampling parity

Nightwatch samples per kind (`sampling.requests`, `.commands`,
`.exceptions`, `.scheduled_tasks`), decided once per execution. Railwatch
is the same hash with `jobs` added:

```ruby
c.sample = { requests: 0.1, jobs: 1.0, commands: 1.0,
             scheduled_tasks: 1.0, channels: 1.0, exceptions: 1.0 }
```

Same semantics: sampled in means the whole tree ships, sampled out means
nothing ships — except an unhandled exception, which is governed by the
`exceptions` rate and flushed immediately. Counters on the parent
(queries, cache events, mail, ...) are incremented even when the
execution is sampled out, so aggregate rates don't depend on the sample
rate.

Nightwatch's `Sample::rate(0.5) / always() / never()` route middleware
becomes a controller macro:

```ruby
class ReportsController < ApplicationController
  railwatch_sample 0.01, only: :index
  railwatch_never_sample only: :health
end
```

Both take the same options as `before_action`. Programmatically:
`Railwatch.sample(rate)`, `Railwatch.dont_sample`, `Railwatch.sampling?`.

**What Railwatch adds: tail sampling.** Head sampling throws away exactly
the slow requests you wanted. Set `c.tail_sample_slow_ms = 500` and a
head-sampled-out execution keeps buffering its children and is kept at
the end if it ran that long, raised, or called `Railwatch.keep!`. Its
parent record carries `tail_sampled: true` so it stays distinguishable
from a head-sampled one.

```ruby
c.sample = { requests: 0.05 }   # 5% of requests...
c.tail_sample_slow_ms = 500     # ...plus every one over 500ms
Railwatch.keep!                   # ...plus this one, whatever the roll said
```

The trade-off is memory: with tail sampling on, every sampled-out
execution buffers its child records for its lifetime (capped at 10,000
per execution) instead of discarding them as they happen. With it off —
the default — nothing is built or buffered for a sampled-out execution
at all.

**And failure context.** Nightwatch, like Railwatch before this, ships an
unsampled execution's unhandled exception with its parent record and
nothing else: no queries, logs or outgoing requests from the moments
before it. Set `c.failure_context = 200` and a head-sampled-out
execution keeps its last 200 child records in a ring, shipping them only
if it reports an unhandled exception. It is the failure half of tail
sampling without the memory bill of keeping every sampled-out execution
alive; the two are independent, and tail sampling's larger buffer wins if
both are set. See `docs/configuration.md`.

## Facade parity

Same facade, Ruby names:

| Nightwatch | Railwatch |
|---|---|
| `Nightwatch::user($cb)` | `Railwatch.user { \|user\| ... }` (or `c.user { }`) |
| `sample($rate)` | `Railwatch.sample(rate)` |
| `dontSample()` | `Railwatch.dont_sample` |
| `sampling()` | `Railwatch.sampling?` |
| `ignore($cb)` | `Railwatch.ignore { }` |
| `pause()` / `resume()` / `paused()` | `Railwatch.pause` / `Railwatch.resume` / `Railwatch.paused?` |
| `report($e, $handled)` | `Railwatch.report(error, handled: true)` |
| `redactRequests` / `redactQueries` / `redactExceptions` / `redactCacheEvents` / `redactCommands` / `redactMail` / `redactOutgoingRequests` | `Railwatch.redact_requests`, `redact_queries`, `redact_exceptions`, `redact_cache_events`, `redact_commands`, `redact_mail`, `redact_outgoing_requests`, plus `redact_logs` |
| `rejectQueries` / `rejectCacheEvents` / `rejectMail` / `rejectNotifications` / `rejectOutgoingRequests` / `rejectQueuedJobs` | `Railwatch.reject_queries`, `reject_cache_events`, `reject_mail`, `reject_notifications`, `reject_outgoing_requests`, `reject_enqueued_jobs`, plus `reject_broadcasts` and `reject_logs` |
| `rejectCacheKeys([...])` | `Railwatch.reject_cache_keys(%w[session: rack::attack*])` |
| `captureDefaultVendorCommands` / `CacheKeys` | `c.capture_default_vendor_commands` / `c.capture_default_vendor_cache_keys` |
| `guzzleMiddleware()` | `Railwatch::Faraday` (`Faraday.new(url) { \|f\| f.use Railwatch::Faraday }`); `Net::HTTP` is covered globally with no setup |
| `IngestingEvents` listener returning `false` | `Railwatch.before_ingest { \|batch\| ... }` |

Beyond the facade: `Railwatch.context(**attrs)` (Laravel Context's
counterpart, writing through to all three of Rails' own context stores),
`Railwatch.span(name, **attrs) { }`, `Railwatch.keep!`,
`Railwatch.attach(name, data)`, `Railwatch.fingerprint { }`,
`Railwatch.instrument_outgoing(method, url) { }`,
`Railwatch.on_unrecoverable { }`, and `Railwatch.flush`.

## Config and commands

`config/nightwatch.php` becomes `config/initializers/railwatch.rb`, and
every setting still has an env var — `NIGHTWATCH_*` becomes `RAILWATCH_*`.
`filtering.ignore_*` becomes one list, `c.ignore = [:cache_events,
:queries, ...]`, validated at assignment. `filtering.log_level` becomes
`c.log_level`. `ingest.uri`, `.timeout`, `.connection_timeout`, and
`.event_buffer` become `c.ingest_url`, `c.timeout`,
`c.connect_timeout`, and `c.buffer_size`.

| Nightwatch | Railwatch |
|---|---|
| `nightwatch:agent` | Nothing — the reporter thread lives in the app process. |
| `nightwatch:status` | `bin/rails railwatch:status` |
| `nightwatch:deploy {deploy} --ref --name --url` | `bin/rails railwatch:deploy[ref,name,url]`, or the generated `.kamal/hooks/post-deploy` |
| — | `bin/rails railwatch:doctor`, which checks the whole install and exits non-zero if the token or the ingest host is wrong |

## The three things worth knowing about Rails

**Tenancy is first class.** Nightwatch tells you to prefix user ids by
hand. Railwatch reads `ActiveRecord::Base.current_tenant` /
`TenantRecord.current_tenant` (`activerecord-tenanted`) with zero config,
stamps `tenant` on every record, and gives you a Tenants page.
`Railwatch.context(tenant: org.slug)` sets it explicitly for apps that
roll their own.

**Jobs are instrumented at Active Job**, not per adapter, so Solid Queue,
Sidekiq, and anything else with an Active Job adapter all report the same
`job_attempt` fields. Scheduled tasks are Solid Queue recurring tasks,
so cron monitoring needs no check-in calls.

**Your test suite is a performance gate.** The same instrumentation runs
under RSpec and Minitest, so a query budget can be checked in and CI can
fail the pull request that regresses it:

```ruby
expect { get "/widgets" }.to have_railwatch_queries(at_most: 6)
expect { get "/widgets" }.not_to have_railwatch_n_plus_one
```

See [`testing.md`](testing.md).

## Next

- [`getting-started.md`](getting-started.md) — install, in five minutes.
- [`configuration.md`](configuration.md) — every option and env var.
- [`records.md`](records.md) — all 26 record types, field by field.
