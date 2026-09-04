# Changelog

## 0.1.0 (unreleased)

- Browser JavaScript errors. The Inertia browser client now captures
  uncaught errors, unhandled promise rejections, and Inertia's `exception`
  and `invalid` events, batches them onto the existing beacon, and the
  beacon controller records each as an `exception` with `source: "browser"`
  — stack parsed into the same `{file, line, function, in_app}` frames a
  Ruby backtrace produces, and the same default fingerprint, so a browser
  error groups, regresses and resolves like any other issue. Each error
  carries the page URL, Inertia component, visit, tab session, user agent,
  and the last 20 breadcrumbs (console errors, clicks, navigations).
  `startLantern({ ignoreErrors, denyUrls, tenant })` and a new exported
  `reportError(error, context)` for React error boundaries. Replaces
  `@sentry/react`; see `docs/replacing-sentry.md`.

- Release health: a new `session` record type, from the browser client (one
  session per tab, riding along on the visit beacon) and from the request
  middleware (`Lantern::Sessions`, one flusher thread per web process).
  `config.track_sessions`, `config.session_flush_interval`,
  `config.session_timeout`; `c.ignore = [:sessions]` turns off shipping.

- Added `docs/records.md` (every wire record type, field by field) and
  `docs/configuration.md` (every `Configuration` attribute, the public
  facade, sampling, transport, Inertia beacon/SSR, the overhead gate, the
  Kamal hook, and the rake tasks); README tightened to point at both,
  plus a new "Replacing Sentry" section.
- Initial release: requests, jobs, scheduled tasks, commands, queries (with
  N+1 detection), transactions, exceptions, cache, mail, Action Cable
  broadcasts, Noticed notifications, outgoing HTTP, Active Storage, view
  renders, logs and Rails 8.1 structured events, deprecations, users,
  processes, and Inertia visits. Sampling, ignore/pause, redaction,
  rejection, before-ingest rate limiting, deploy tracking, Kamal hook.
- Job attempts report `status` (`released` when `retry_on` re-enqueues instead
  of failing), `queue_latency` measured at perform-start rather than after the
  job runs, `connection`, and `concurrency_key`; a pruned job attempt gets a
  fresh `execution_id`/`trace_id` instead of reusing a stale one.
- `process` records measure `boot_seconds` from `Lantern::BOOTED_AT`, a clock
  reading taken as early in process boot as Lantern can observe, instead of an
  unset global.
- `bin/rails runner` invocations are instrumented as a `command` execution.
- Inertia SSR renders are timed automatically (`inertia.ssr_ms`) wherever
  `inertia_rails` SSR is enabled, including full-page (non-XHR) visits.
- Exceptions report `code` (errno, for a `SystemCallError`) and `sql_state`.
- Transactions report `statement_count` (writes made inside the transaction)
  and a `group` hash for grouping in the UI.
- Default vendor rake tasks (`db:migrate`, `assets:precompile`, ...) and
  default vendor cache-key prefixes (`rack::attack`, `flipper`, ...) are
  excluded by default; opt back in with `capture_default_vendor_commands` /
  `capture_default_vendor_cache_keys`.
- `Lantern.reject_cache_keys` drops your own noisy cache keys the same way as
  the default vendor list, with trailing-`*` prefix matching and regex support.
- A request sampled out together with `sample[:exceptions] = 0` now ships
  nothing for an unhandled exception, instead of always shipping one.
- Requests report `route_methods`, `route_domain`, and uploaded `files`
  (name/size/content_type only, never file contents).
- `Lantern.on_unrecoverable` registers a callback for Lantern's own internal
  errors (a subscriber raising, or delivery failing after its retry).
- `Lantern::Faraday` middleware instruments outgoing HTTP made through
  Faraday (`f.use Lantern::Faraday`); `Lantern.instrument_outgoing(method,
  url) { }` covers any other HTTP client.
- Fixed `Backtrace.caller_location` excluding legitimate app/spec frames that
  happened to live under a path containing "/lantern/" (this gem's own
  `spec/dummy`, for one); it now only skips Lantern's own `lib/` and frames
  inside an installed gem, so query and outgoing-request source locations
  resolve correctly again.
- Fixed `lantern:status` and `lantern:deploy` rake tasks running twice per
  invocation: the engine no longer manually `load`s `lib/tasks/lantern_tasks.rake`
  on top of Rails' automatic `lib/tasks/*.rake` loading.
- `Transport::Http` is now HTTP-status-aware: a 5xx response is retried once,
  a 4xx is not retried, a 401 marks the reporter unauthorized and stops
  flushing (logged once via `Lantern.debug` and `Lantern.on_unrecoverable`),
  and a 402 (quota) backs off for 60 seconds, dropping and counting records
  as dropped during the backoff window. Delivery still never raises.
- Fixed `Patches::RakeTask` shipping a separate command record per
  prerequisite instead of nesting the whole dependency chain under one
  command execution; nested calls made from inside an already-excluded
  vendor task (e.g. `db:_dump`, invoked internally by `db:migrate`) are also
  left untracked instead of starting their own execution.
- `job_attempt` records now include `parent_id` (the enqueuing execution's
  id), previously captured but never emitted in the shipped hash.
- Fixed `Patches.install_runner_command!` requiring the wrong path for
  `Rails::Command::RunnerCommand` (`rails/command/runner_command` instead of
  `rails/commands/runner/runner_command`), which silently no-oped and left
  `bin/rails runner` uninstrumented.
- `Configuration#ignore=` now raises `ArgumentError` for a record type
  outside `RECORD_TYPES` instead of silently accepting it.
- `scheduled_task` records report `drift` (microseconds between the
  `RecurringExecution#run_at` and the actual perform start).
