# Changelog

## 0.1.0 (unreleased)

- A `user` entity is now cached (one per id per process-hour) only after the
  execution that carried it was actually handed to the reporter. Previously
  the first sighting wrote the cache entry unconditionally, so if that
  sighting happened inside a sampled-out or `Lantern.pause`d execution -- or
  an execution whose sampling flipped afterwards -- no `user` record was ever
  written, and every sampled-in sighting for the next hour was suppressed:
  the platform had records attributed to a user it had no name or email for.
  Forked workers also reset the cache, since a child's reporter buffer starts
  empty and has to emit its own entities.



- Action Cable channel actions now open a real `channel_action` execution
  before application code runs, so the queries, logs, broadcasts, transmits,
  and unhandled exceptions inside an action share one execution and one trace.
  A channel action has no HTTP request and no Rack middleware around it, so
  until now those records had no parent at all. Head sampling is its own knob,
  `sample[:channels]` / `LANTERN_CHANNEL_SAMPLE_RATE`; an unhandled channel
  exception still ships with its parent when the channel rate is zero.
  **lantern-cloud must accept the `channel_action` record type before this
  ships** — that is being handled separately.

- `Lantern.context` is now redacted with the same `ActiveSupport::ParameterFilter`
  that redacts request params. Context is application data and gets copied
  onto every record built while it is set, so an app that put an API token or
  a password there was writing it verbatim into telemetry.
- An oversized context is now rebuilt rather than sliced. The 64KB cap used
  to `byteslice` the encoded JSON, which cut it mid-string or mid-object and
  left the platform with an unparseable fragment -- the whole context was
  lost rather than most of it. Whole values are kept while they fit, an
  oversized string value ends with `[TRUNCATED]`, anything that still does
  not fit is dropped, and `"_lantern_truncated": true` says it happened. The
  empty-context fast path (which runs on every log record) is unchanged.

- Request teardown no longer parses a non-multipart request body. Emitting
  the `request` record read `request.params` (for `files`) and
  `request.format`, and Rack parses the body the first time either is asked
  for. When a controller ran, that parse had already happened and was
  memoized; when nothing ran -- a routing 404, a rack-attack block, an
  upstream rejection -- Lantern was the only component that ever read the
  body, at teardown, after the response was decided. Both reads are now
  guarded: `files` falls back to walking params only for a multipart request
  (nothing else can carry an upload), and `format` is reported only when it
  is already resolved or the request is multipart, otherwise `""`.

- Ingest acknowledgements are validated before a batch is considered
  delivered: a 2xx whose body is not a JSON object, is malformed JSON, omits
  `accepted`/`rejected`, or reports counts that do not cover the submitted
  batch now retains the batch (under the same idempotency key) for retry
  instead of silently dropping it. HTML sign-in pages from an intercepting
  proxy were the motivating case. Two shapes are explicitly a successful
  drain rather than a failure: an acknowledgement carrying a `reason`, and an
  all-zero `{"accepted":0,"rejected":0}` -- that is how the platform answers
  for a paused or over-quota environment, and retrying it would burn eight
  attempts and drop the records anyway. Per-record rejections
  (`rejected > 0`) stay routine: they are logged under `LANTERN_DEBUG` and
  are not reported to `on_unrecoverable`, since the platform's ingest batch
  is the authoritative accounting for them.

- The installer now prefers a hidden prompt, stdin, or `LANTERN_TOKEN`, never
  prints token values, and refuses to put a token in a tracked or non-ignored
  `.env`. `lantern:doctor` also fails when it finds a plaintext `lt_...` token
  in likely secret-bearing files tracked by Git. The legacy `--token=` option
  remains compatible but warns about shell-history and process-list exposure.

- A forked worker profiles again. `Process._fork` now resets the profiler's
  process-global state in the child: it used to inherit `@running` holding
  the handle of a profile the parent was taking, which nothing in the child
  ever stopped, so every execution in that worker was counted as skipped and
  never profiled for the life of the process.

- Numeric `LANTERN_*` environment variables are parsed with `Integer()`/
  `Float()` and fall back to the documented default when the value is not a
  number. `LANTERN_BUFFER_SIZE=12px` used to become `0` via `String#to_i`,
  silently turning off buffering; the same applied to timeouts, intervals
  and sample rates.

- Inbound `traceparent` parsing follows the W3C trace-context validity
  rules: version `ff`, an all-zero trace id, and an all-zero parent id are
  rejected instead of being adopted as a trace, and trailing data after the
  flags is rejected on version `00`. A future version that appends
  dash-delimited fields after the flags is now accepted (its extra fields
  are never interpreted) rather than dropped, so a newer upstream still
  links to this service.

- The request record's `url` and `redirect_to` URL fields now retain only
  origin (without authority credentials) and path. Query strings and
  fragments are always removed from these fields, preventing reset tokens,
  OAuth codes, signed-URL credentials, and other parameter values from being
  exported even when request-payload capture is disabled. The Net::HTTP and
  Faraday patches sanitize an `outgoing_request` URL through the same
  helper, so authority credentials and fragments are now dropped there too.

- Exception deduplication is now scoped to the current execution and to the
  handled/unhandled disposition, and only marks an error after sampling and
  pause checks pass. A sampled-out or paused handled report can no longer
  suppress a later unhandled raise of the same object, while Rails.error and
  middleware still collapse duplicate observations in one execution.

- Header masking no longer depends on an app enumerating every vendor
  header name. A header whose name has a credential-shaped segment
  (`api-key`/`apikey`, `access-key`/`accesstoken`, `private-key`,
  `auth`/`authentication`/`authorization`, `bearer`, `credential`, `hmac`,
  `jwt`, `token`, `secret`, `signature`) is masked as `[FILTERED]` on top of
  the exact `redact_headers` denylist. Concatenated Rack aliases such as
  `X-AuthToken`, `X-ApiToken`, `X-AccessToken`, `X-ClientToken`,
  `X-SessionToken`, `X-RefreshToken`, `X-SecretKey`, `X-HmacSignature`, and
  `X-CSRFToken` are covered alongside `X-Api-Key`, `Stripe-Signature`, and
  `X-Hub-Signature-256`. Ordinary diagnostic headers are untouched.

- `buffer_size` defaults to 10,000 (was 5,000), matching
  `Execution::MAX_RECORDS`. A job whose tree was larger than the queue lost
  its first records when the tree was written at the end of the execution;
  on rebulk-system that was every outgoing HTTP request of a 30-second sync.

- Active Job payloads now carry the enqueuing execution's user and tenant
  (`lantern_user`/`lantern_tenant`) next to the trace and parent ids, and
  the worker restores them before the attempt opens. A `job_attempt` and
  every child record under it are attributed to the person whose request
  enqueued the job instead of to a worker process with no signed-in user,
  and jobs that enqueue jobs pass the same identity along. Identifier
  strings only — no user or tenant model is serialized or hydrated.
  Payloads without the keys (enqueued before this change) deserialize to
  nil and fall back to local resolution as before.

- `c.failure_context = 200` (`LANTERN_FAILURE_CONTEXT`) keeps a
  head-sampled-out execution's last 200 child records in a ring and ships
  them only if that execution reports an unhandled exception, so an
  unsampled failure is diagnosable without enabling slow-request tail
  sampling globally. Off (0) by default, which leaves the sampled-out path
  building and buffering nothing exactly as before. `exceptions: 0`,
  ignored and handled exceptions, `Lantern.pause`/`ignore`, and an
  interactive `rails runner` never promote a ring; overflow is counted onto
  the batch's dropped-record count; with `tail_sample_slow_ms` also set,
  tail sampling's larger buffer wins.

- A retained delivery batch gives up after `Reporter::MAX_RETRY_ATTEMPTS`
  (8) and is dropped and counted, so a batch that keeps failing cannot pin
  itself in memory while every newer record is discarded around it.

- `c.beacon_user { |request| ... }`: who is behind a browser beacon, for
  apps that authenticate in a `before_action` the gem's beacon controller
  never runs. Before this, every visit, browser session and JavaScript
  error from such an app shipped with no user.
- Console breadcrumbs render objects as JSON instead of `[object Object]`.

- `bin/rails runner` from a shell never got its command execution: the
  runner patch is prepended during `boot_application!`, which the
  already-running `#perform` calls, so the `#perform` override only ever
  ran in this gem's own specs. The patch now also wraps
  `conditional_executor`, which that `#perform` reaches after boot, so a
  real runner ships its `command` record and an interactive one (`-`,
  inline code, a script under `/tmp`) withholds its exception as documented.

- Forked Puma and Active Job workers now replace inherited reporter buffers,
  drop accounting, transport policy state, and synchronization primitives
  before recording anything. Parent telemetry is delivered only by the
  parent; each child emits its own process/health records, and a mutex held
  by another thread at fork can no longer deadlock the child reporter.

- Exceptions whose backtrace was assigned rather than raised
  (`ActiveRecord::StatementInvalid` via `set_backtrace`, `Faraday::Error`
  delegating to its wrapped exception) shipped with no frames, no
  culprit, and a fingerprint of class and message only, because
  `backtrace_locations` is nil for them. `Backtrace.frames` now parses the
  String backtrace in that case.

- Request exclusions now bypass instrumentation correctly. `/up` and
  `/lantern/beacon` are excluded by default, apps can configure exact paths
  or regexps through `ignored_request_paths`, and a same-origin authenticated
  reporter POST to `/ingest` is recognized behind reverse proxies. The last
  case prevents Lantern Cloud's self-monitoring from creating an endless
  flush -> ingest-request -> flush feedback loop without hiding unrelated
  application routes also named `/ingest`.

- Retryable ingest failures no longer discard a drained batch. Network
  failures plus HTTP 402, 408, 429, and 5xx responses restore records and
  their drop accounting to the bounded buffer, then retry on the reporter
  thread with jittered exponential backoff. Permanent client rejections and
  shutdown deadlines with unsent records remain observable through
  `on_unrecoverable`; urgent exception reporting now wakes the background
  thread instead of waiting through network timeouts on the request thread.

- Browser JavaScript errors. The Inertia browser client now captures
  uncaught errors, unhandled promise rejections, and Inertia's failed-request
  events (`exception`/`invalid` on Inertia 2, `networkError`/`httpException`
  on Inertia 3), batches them onto the existing beacon, and the
  beacon controller records each as an `exception` with `source: "browser"`
  — stack parsed into the same `{file, line, function, in_app}` frames a
  Ruby backtrace produces, and the same default fingerprint, so a browser
  error groups, regresses and resolves like any other issue. Each error
  carries the page URL, Inertia component, visit, tab session, user agent,
  and the last 20 breadcrumbs (console errors, clicks, navigations).
  `startLantern({ ignoreErrors, denyUrls, tenant })`, plus
  `lanternRootOptions()` for React 19's `createRoot` and
  `reportError(error, context)` for a React 18 boundary — outside a
  development build React never hands a boundary-caught error to
  `window.onerror`. Replaces `@sentry/react`; see
  `docs/replacing-sentry.md`.

- Interactive sessions are no longer treated as application failures.
  `bin/rails console` captures nothing, starts no background thread, and
  sends no `process`/`health` record (`config.capture_console` /
  `LANTERN_CAPTURE_CONSOLE=1` re-enables everything). A `bin/rails runner`
  the operator typed (`-`, inline code, or a `.rb` file under
  `config.interactive_runner_paths`, default `/tmp/` and `/var/tmp/`) ships
  its `command` record with `interactive: true` and its exit code, but does
  not report the exception; a deployed script (`rails runner
  script/nightly.rb`), a rake task, and a job report exactly as before.

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
