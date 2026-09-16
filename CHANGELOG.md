# Changelog

## Unreleased

- A rake task or `rails runner` no longer waits out the full timeout ladder
  on exit when the Railwatch server accepts connections but never answers.
  The end-of-command flush and the `at_exit` shutdown are both bounded by
  `shutdown_timeout` (default 2s): the connect timeout is clamped to what
  remains of it, read and write are re-clamped once the socket is open, the
  transport's one retry is skipped once it has passed, and whatever is
  still unsent is retained and reported through `on_unrecoverable` as
  before. The bound is per socket operation, as Net::HTTP's timeouts are;
  a server that sends nothing is cut off in one wait, which is the case
  this exists for. Previously each such process paid
  ~8s (two read timeouts plus the shutdown flush), which turned a wedged
  Railwatch into a failed deploy for an app whose container entrypoint boots
  Rails eleven times before its server. `Transport::Http#deliver` takes an
  optional monotonic `deadline:`; a custom transport that does not accept
  it is called exactly as before.

## 0.1.4 (2026-09-15)

- `llm_call` records what the call carried and how it was configured, not
  just what it cost. `finish_reason` shows when an answer was cut off
  (`max_tokens`) or filtered, which previously read exactly like a complete
  one. `attachments` and `attachment_types` show that a call carried two
  images and a PDF, so a document read is no longer indistinguishable from
  an expensive prompt -- on a document-reading call the attachments are most
  of the input tokens. `params` holds the settings that produced the answer
  (temperature, max_output_tokens, tool_choice, thinking, caching, whether a
  schema was used, and the per-operation ones) so a surprising result can be
  reproduced. `tools` names what the model could reach; `tool_call_id` joins
  a tool call to the turn that asked for it.
- `provider_request_id` is read from the response headers (`request-id`,
  `x-request-id`, `x-amzn-requestid`). It is the only key that joins a
  Railwatch record to the provider's own record of the same call, and it is
  what a provider support ticket asks for.
- `cost_reported` distinguishes a price the provider stated from one
  estimated against the model registry.
- `provider_options` is filtered twice before it is stored: through the
  app's own parameter filter, and again against the credential-name matcher
  that catches `X-Api-Key` on a header. The default parameter filter is
  password-shaped, so an `api_key` passed per call went through it
  untouched. Attachment filenames stay behind `capture_llm_content`, since
  a filename is business data rather than metadata.

## 0.1.3 (2026-09-15)

- LLM calls are recorded from RubyLLM's own instrumentation. Every model
  call it emits -- `chat`, `compaction`, `embedding`, `image`, `speech`,
  `transcription`, `moderation`, `rerank`, `ocr` -- plus each tool
  invocation becomes one
  `llm_call` child record on the request, job, or command that made it,
  carrying provider, model, duration, token counts per bucket, and cost.
  Nothing is patched: RubyLLM publishes ActiveSupport::Notifications events
  and Railwatch subscribes to them like any Rails event.
- Both RubyLLM generations are read from the same subscriber. 1.16 puts
  token counts on the event as scalars and reports no cost; 2.0 sends its
  `Tokens` and `Cost` objects, and stamps `workflow_id` and step identity on
  every event inside `RubyLLM.workflow`, which is recorded so an agent run
  can be reassembled from its steps. A 1.16 app has no cost rather than a
  cost of zero, and a model the registry cannot price is unpriced, not free.
- `capture_llm_content` (default off, `RAILWATCH_CAPTURE_LLM_CONTENT`)
  records the last user turn and the reply, capped at 4 KiB of bytes each. Token
  counts, model, and cost are always captured; prompts are not, because
  they are whatever the app sent a provider.

## 0.1.2 (2026-09-14)

- A failed job's exception is reported once. Solid Queue re-raises it out
  of the worker thread, where its app executor reports the same error object
  to `Rails.error` again after the `job_attempt` execution has finished; that
  second report (source `application.solid_queue`, unlinked) doubled every
  failed job's occurrence count. An error object now remembers that its
  unhandled report has shipped, across executions.
- `require "railwatch/minitest"` includes the assertions into
  `ActiveSupport::TestCase` through its load hook, so `assert_railwatch_queries`
  works after the generator's one-line edit to `test/test_helper.rb` without
  a manual `include`.
- Solid Queue's supervisor, dispatcher, scheduler, and forked workers report
  role `worker` after Solid Queue renames the process. They were classified
  `web` by every health sample taken after boot, with empty Puma thread
  stats.
- Troubleshooting entries for `json` 3.0 against Rails 8.1.3.1 (`bin/jobs`
  crash loop, not a Railwatch fault) and for deprecations that are counted
  but never listed because the app's deprecation behavior lacks `:notify`.

## 0.1.1 (2026-09-14)

- Token prefixes are `rw_` for an environment's ingest token and `rwp_`
  for a personal API and MCP token. They were `lt_` and `lnt_`, Lantern's
  initials, which no longer name anything a user can see. The platform
  authenticates by digest, so tokens minted before this keep working; the
  doctor's plaintext-token scan matches both the old and the new ingest
  prefix.

## 0.1.0 (2026-09-14)

First public release.

- Renamed the gem from Lantern to Railwatch: constants, file paths,
  `X-Railwatch-*` headers, `RAILWATCH_*` environment variables, rake tasks,
  the generator, the `/railwatch` mount, and the `railwatch` distribution name.
  There is no compatibility layer.
- Prepared the gem for its public RubyGems distribution. Added strict package
  verification, Trusted Publishing release automation, public
  security/contribution guidance, TLS verification assertions, an
  HTTPS-by-default ingest policy, and browser beacon payload hardening.

- Deploy detection follows a git worktree's `.git` file to its gitdir and
  resolves the branch through the repository's refs, so a development app
  checked out as a worktree gets a deploy value like a plain clone.

- Reporter backpressure now smooths sustained bursts before the bounded queue
  starts losing whole executions. On each existing reporter tick, a buffer at
  80% of either its record or byte ceiling, or an active ingest retry ladder,
  doubles every execution kind's effective sample divisor up to 8; clear ticks
  halve it back to 1. It is enabled by default and configurable with
  `backpressure` / `RAILWATCH_BACKPRESSURE` and `backpressure_high_water` /
  `RAILWATCH_BACKPRESSURE_HIGH_WATER`. The current divisor rides on deliveries
  as `X-Railwatch-Backpressure-Factor`, and resets after fork.

- Active Job retries can optionally capture the exception that caused the
  retry as handled, warning-level telemetry with its attempt and wait in
  context (`capture_job_retry_errors`,
  `RAILWATCH_CAPTURE_JOB_RETRY_ERRORS`). It is off by default because retries
  are usually expected and enabling it can flood the issues list. The
  existing retry log is unchanged.

- Deploy identifiers are auto-detected without spawning Git: explicit Railwatch
  and Kamal values first, then common Heroku, Render, Fly, Vercel, GitLab,
  GitHub, and build environment variables, a Capistrano `REVISION`, and the
  checkout's loose or packed Git ref. Full SHAs are consistently shortened to
  12 characters. `RAILWATCH_DETECT_DEPLOY=false` opts out of inferred values,
  and `railwatch:doctor` reports the selected source.

- `health` records carry the recurring task schedule Solid Queue is
  running (`detail.recurring_tasks`, key => schedule), so the platform can
  tell a task that was removed from `config/recurring.yml` apart from one
  that stopped running. Railwatch Cloud used to flag a removed task as
  missed every ten minutes for thirty days after its last run. Left out,
  not sent empty, when there are no tasks or the table could not be read.

- The browser client reports a dropped Inertia request (`networkError` on
  Inertia 3, `exception` on 2) only while the user is waiting on a visit,
  meaning one that shows Inertia's progress bar. A visit the page started by
  itself — a poll, a refresh when the tab comes back, `router.reload`, a
  prefetch on hover — runs without it, and when one drops its connection
  nothing the user did has failed: the page keeps what it has and the next
  tick refreshes it. A laptop waking on a new network used to open an issue
  that way, and regress it every morning. The visit still lands in timing
  data with `status: "cancelled"`. A click or a form submit is reported as
  before, including a click Inertia serves from a prefetch already in
  flight (which never gets a `start` of its own), and so is the load of a
  page's deferred props, which the user watches as a skeleton; an app that
  wants a particular background refresh reported passes `showProgress:
  true`. Inertia re-rejects a failed request's error after firing the
  event, and the client now drops that unhandled-rejection copy by identity
  rather than relying on the reported record to dedupe it.

- Boot with the gem enabled is now within noise of boot without it; it was
  about 300 ms and 10 MB slower.
  The `process` record read its adapter names through `ActiveRecord::Base`
  and `ActiveJob::Base`, which autoloaded both frameworks before anything
  else asked for them; it now reads the app's configuration. The Rake and
  `bin/rails runner` patches are installed from the engine's `rake_tasks`
  and `runner` hooks instead of every boot, which stops a web or worker
  process requiring rake and railties' runner command.
- The `process` record is written from an `after_initialize` hook that
  the engine registers from inside an initializer, so it runs after every
  `after_initialize` block the app itself registers; `boot_seconds` covers
  the app's own initializers and those blocks, and an app that reconfigures
  Railwatch late is respected.
- Fork handling is one `ActiveSupport::ForkTracker` callback -- Rails' own
  `Process._fork` hook -- instead of three separate prepends on `Process`.
  `Railwatch::Reporter::ForkHook`, `Railwatch::Health::ForkHook`, and
  `Railwatch::Sessions::ForkHook` are gone; `Railwatch.restart_after_fork!`
  resets everything in order.
- The gemspec declares `base64` (a bundled gem since Ruby 3.4, previously
  reached only through Active Support's own dependency) and bounds the
  Rails dependency to `>= 8.1, < 9`.

- An unhandled exception's urgent flush is coalesced over a quarter-second
  window (`Reporter::URGENT_FLUSH_DELAY`) instead of waking the reporter
  per record. During an exception storm every request used to trigger its
  own POST carrying the handful of records written since the last one: a
  ten-second burst that produced 4,000 records went out as 400 POSTs of
  ten, at about double the gzip bytes per record of a full batch. A lone
  exception still ships within the window; a buffer that crosses
  `flush_threshold` flushes at once as before.

- `POST /railwatch/beacon` is rate limited per client IP: 120 requests a
  minute by default (`beacon_rate_limit`, `RAILWATCH_BEACON_RATE_LIMIT`; `0`
  disables), answered with 429 and `Retry-After` past that. The beacon takes
  no credential and keeps every browser error it is sent, so until now a
  script could spend an app's event quota and open junk browser issues from
  a shell. The counter lives in the app's cache store; a store that cannot
  count fails open.
- **Behaviour change for every app: `query` records now carry normalized SQL,
  not the raw statement.** String, numeric, hex, Postgres dollar-quoted and
  adapter-specific literals, plus SQL comments, are replaced with `?` while
  the statement shape and placeholders remain. SQL literals routinely contain
  email addresses, tokens, and other customer data, and until now every one of
  them was shipped. Set `capture_sql_values` (`RAILWATCH_CAPTURE_SQL_VALUES`) to
  restore the old behaviour. Active Record's separate structured binds are
  never sent either way, and `capture_query_explain` is unaffected -- the
  EXPLAIN still runs on the raw statement, only what is stored in `sql`
  changed. Note that a plan can echo literal predicates, so
  `capture_query_explain` remains a privacy decision of its own.
- The SQL normalizer is a byte-oriented lexical scanner rather than a set of
  regexes: adapter-aware quoting (MySQL backticks and double-quoted strings,
  SQLite `[ident]` and its double-quoted-string fallback, Postgres
  dollar-quoting and `E''`), nested block comments, and bounded input. It
  scans each dialect's *default* backslash-escaping rule. Session modes that
  change that rule (`NO_BACKSLASH_ESCAPES`, `standard_conforming_strings =
  off`) are not carried in the notification; the previous approach of
  abandoning the rest of the statement whenever a backslash-quote appeared
  was worse, because on MySQL -- where backslash escaping is the quoting
  Active Record emits -- it truncated every statement containing an
  apostrophe and collapsed distinct queries into one group.

- Telemetry memory is now bounded by bytes as well as by record count. A
  record count alone does not bound memory: 10,000 records is a few megabytes
  of ordinary telemetry, or a gigabyte of captured attachments and
  multi-megabyte SQL strings. Three new ceilings, all configurable:
  `buffer_bytes` (16 MiB, reporter queue), `execution_buffer_bytes` (8 MiB,
  one execution's buffered tree), and `batch_bytes` (8 MiB uncompressed
  NDJSON per ingest request). Each record is weighed once, when it is
  buffered, and the weight travels with it, so nothing is measured twice.
  Byte loss is counted and reported alongside record loss
  (`X-Railwatch-Dropped-Bytes`).
- A queue holding more than one batch is delivered as several batches; the
  tail is kept for the next flush rather than dropped. A record that still
  does not fit one delivery is dropped and counted rather than raising -- a
  batch that is too large is exactly as large on the next attempt, so
  retrying it would burn all eight attempts and drop it anyway.
- `Railwatch.attach` reads a file or IO with a bounded `cap + 1` read. A 2GB
  log file used to be read whole and then sliced to 1 MiB.

- User references survive a tenant that binds after the user is resolved.
  An app that resolves its user in one `before_action` and its tenant in the
  next used to emit a bare `"1"` for every tenant's user 1 -- two tenants
  collapsed onto one person on the platform. The execution now keeps the raw
  id and requalifies it (plus the records already buffered, and the pending
  `user` entity) the moment the tenant binds, so the final reference is
  `"acme:1"` and the entity is deduplicated against that final reference
  rather than the provisional one. Jobs enqueued from such a request carry
  the raw id and the tenant, and the worker qualifies it on restore.
- `Railwatch.context(tenant: ...)` now actually sets the tenant on records, as
  documented. It binds onto the running execution at `Railwatch.context` time;
  `Context.current_tenant` reads that before falling back to `TenantRecord` /
  `ActiveRecord::Tenanted`, so nothing on the per-record path pays for it.

- A `user` entity is now cached (one per id per process-hour) only after the
  execution that carried it was actually handed to the reporter. Previously
  the first sighting wrote the cache entry unconditionally, so if that
  sighting happened inside a sampled-out or `Railwatch.pause`d execution -- or
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
  `sample[:channels]` / `RAILWATCH_CHANNEL_SAMPLE_RATE`; an unhandled channel
  exception still ships with its parent when the channel rate is zero.

- `Railwatch.context` is now redacted with the same `ActiveSupport::ParameterFilter`
  that redacts request params. Context is application data and gets copied
  onto every record built while it is set, so an app that put an API token or
  a password there was writing it verbatim into telemetry.
- An oversized context is now rebuilt rather than sliced. The 64KB cap used
  to `byteslice` the encoded JSON, which cut it mid-string or mid-object and
  left the platform with an unparseable fragment -- the whole context was
  lost rather than most of it. Whole values are kept while they fit, an
  oversized string value ends with `[TRUNCATED]`, anything that still does
  not fit is dropped, and `"_railwatch_truncated": true` says it happened. The
  empty-context fast path (which runs on every log record) is unchanged.

- Request teardown no longer parses a non-multipart request body. Emitting
  the `request` record read `request.params` (for `files`) and
  `request.format`, and Rack parses the body the first time either is asked
  for. When a controller ran, that parse had already happened and was
  memoized; when nothing ran -- a routing 404, a rack-attack block, an
  upstream rejection -- Railwatch was the only component that ever read the
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
  (`rejected > 0`) stay routine: they are logged under `RAILWATCH_DEBUG` and
  are not reported to `on_unrecoverable`, since the platform's ingest batch
  is the authoritative accounting for them.
- Per-request overhead roughly halved, and per-query overhead cut by about
  two thirds, measured against a baseline with the gem's subscribers
  genuinely unsubscribed. The log capture reported itself at DEBUG, which
  made `Rails.logger.debug?` true for the whole app and had every framework
  `LogSubscriber` format its SQL, render, and cache lines for nobody; it
  now reports `config.log_level`. A head-sampled-out request no longer
  builds the request record it was about to discard. The transaction
  statement counter shares the query subscriber's event instead of taking
  a second one per query, and the model-hydration counter subscribes
  without an `Event` object. Cache-event and view-render group hashes,
  the vendor cache-key check, and the `GC.stat(:time)` probe are computed
  once instead of per event.

- `bench/overhead.rb` now measures against a real baseline: every
  subscriber the gem installed is unsubscribed and its log capture detached
  for the "off" batches, rather than flipping `config.enabled` with
  everything still wired in, which had hidden most of the cost. It gates
  three request shapes on SQLite and fails if `Rails.logger.debug?` is on.
  The scripts that produced the numbers in the docs are committed alongside
  it and indexed in `bench/README.md`: per-shape cost, the request, query,
  and exception paths piece by piece, reporter-thread and wire cost,
  allocation and CPU attribution, and an end-to-end Puma load harness.

- The installer now prefers a hidden prompt, stdin, or `RAILWATCH_TOKEN`, never
  prints token values, and refuses to put a token in a tracked or non-ignored
  `.env`. `railwatch:doctor` also fails when it finds a plaintext `lt_...` token
  in likely secret-bearing files tracked by Git. The legacy `--token=` option
  remains compatible but warns about shell-history and process-list exposure.

- A forked worker profiles again. `Process._fork` now resets the profiler's
  process-global state in the child: it used to inherit `@running` holding
  the handle of a profile the parent was taking, which nothing in the child
  ever stopped, so every execution in that worker was counted as skipped and
  never profiled for the life of the process.

- Numeric `RAILWATCH_*` environment variables are parsed with `Integer()`/
  `Float()` and fall back to the documented default when the value is not a
  number. `RAILWATCH_BUFFER_SIZE=12px` used to become `0` via `String#to_i`,
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
  (`railwatch_user`/`railwatch_tenant`) next to the trace and parent ids, and
  the worker restores them before the attempt opens. A `job_attempt` and
  every child record under it are attributed to the person whose request
  enqueued the job instead of to a worker process with no signed-in user,
  and jobs that enqueue jobs pass the same identity along. Identifier
  strings only — no user or tenant model is serialized or hydrated.
  Payloads without the keys (enqueued before this change) deserialize to
  nil and fall back to local resolution as before.

- `c.failure_context = 200` (`RAILWATCH_FAILURE_CONTEXT`) keeps a
  head-sampled-out execution's last 200 child records in a ring and ships
  them only if that execution reports an unhandled exception, so an
  unsampled failure is diagnosable without enabling slow-request tail
  sampling globally. Off (0) by default, which leaves the sampled-out path
  building and buffering nothing exactly as before. `exceptions: 0`,
  ignored and handled exceptions, `Railwatch.pause`/`ignore`, and an
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
  `/railwatch/beacon` are excluded by default, apps can configure exact paths
  or regexps through `ignored_request_paths`, and a same-origin authenticated
  reporter POST to `/ingest` is recognized behind reverse proxies. The last
  case prevents Railwatch Cloud's self-monitoring from creating an endless
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
  `startRailwatch({ ignoreErrors, denyUrls, tenant })`, plus
  `railwatchRootOptions()` for React 19's `createRoot` and
  `reportError(error, context)` for a React 18 boundary — outside a
  development build React never hands a boundary-caught error to
  `window.onerror`. Replaces `@sentry/react`; see
  `docs/replacing-sentry.md`.

- Interactive sessions are no longer treated as application failures.
  `bin/rails console` captures nothing, starts no background thread, and
  sends no `process`/`health` record (`config.capture_console` /
  `RAILWATCH_CAPTURE_CONSOLE=1` re-enables everything). A `bin/rails runner`
  the operator typed (`-`, inline code, or a `.rb` file under
  `config.interactive_runner_paths`, default `/tmp/` and `/var/tmp/`) ships
  its `command` record with `interactive: true` and its exit code, but does
  not report the exception; a deployed script (`rails runner
  script/nightly.rb`), a rake task, and a job report exactly as before.

- Release health: a new `session` record type, from the browser client (one
  session per tab, riding along on the visit beacon) and from the request
  middleware (`Railwatch::Sessions`, one flusher thread per web process).
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
- `process` records measure `boot_seconds` from `Railwatch::BOOTED_AT`, a clock
  reading taken as early in process boot as Railwatch can observe, instead of an
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
- `Railwatch.reject_cache_keys` drops your own noisy cache keys the same way as
  the default vendor list, with trailing-`*` prefix matching and regex support.
- A request sampled out together with `sample[:exceptions] = 0` now ships
  nothing for an unhandled exception, instead of always shipping one.
- Requests report `route_methods`, `route_domain`, and uploaded `files`
  (name/size/content_type only, never file contents).
- `Railwatch.on_unrecoverable` registers a callback for Railwatch's own internal
  errors (a subscriber raising, or delivery failing after its retry).
- `Railwatch::Faraday` middleware instruments outgoing HTTP made through
  Faraday (`f.use Railwatch::Faraday`); `Railwatch.instrument_outgoing(method,
  url) { }` covers any other HTTP client.
- Fixed `Backtrace.caller_location` excluding legitimate app/spec frames that
  happened to live under a path containing "/railwatch/" (this gem's own
  `spec/dummy`, for one); it now only skips Railwatch's own `lib/` and frames
  inside an installed gem, so query and outgoing-request source locations
  resolve correctly again.
- Fixed `railwatch:status` and `railwatch:deploy` rake tasks running twice per
  invocation: the engine no longer manually `load`s `lib/tasks/railwatch_tasks.rake`
  on top of Rails' automatic `lib/tasks/*.rake` loading.
- `Transport::Http` is now HTTP-status-aware: a 5xx response is retried once,
  a 4xx is not retried, a 401 marks the reporter unauthorized and stops
  flushing (logged once via `Railwatch.debug` and `Railwatch.on_unrecoverable`),
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
