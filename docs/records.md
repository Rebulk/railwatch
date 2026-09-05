# Record types

Every record Lantern ships is a flat hash (`lib/lantern/record.rb`). This
lists all 26, field by field, sourced from the subscriber or patch that
builds each one. Field names below are the hash keys as sent over the
wire (symbols in Ruby, strings in the gzip NDJSON payload).

## Shared envelope

Every record carries these (`Record.build`, `lib/lantern/record.rb`):

| Field | Meaning |
|---|---|
| `v` | Record schema version for this type (`Record::VERSIONS`). |
| `t` | Type string, e.g. `"query"`. |
| `timestamp` | Unix seconds (float) when the event started. |
| `deploy` | `Lantern.config.deploy` — `LANTERN_DEPLOY`, `KAMAL_VERSION`, or `GIT_REV`. |
| `server` | `Lantern.config.server` — hostname by default. |
| `_group` | 128-bit grouping hash (MD5 of type-specific parts, `Record.group_hash`) the platform uses to bucket occurrences into one issue/row. |

Records created inside an execution (everything except the five parent
types, plus `user`/`process`/`visit`, which stand alone) also merge in the
execution's envelope (`Execution#envelope`, `lib/lantern/execution.rb`):

| Field | Meaning |
|---|---|
| `trace_id` | Shared by a request and every job it enqueues (`JobTracing`), so a chain of async work traces back to the request that started it. |
| `execution_source` | `"request"`, `"job"`, `"scheduled_task"`, `"command"`, or `"channel_action"`. |
| `execution_id` | UUID of the parent execution this child belongs to. |
| `parent_id` | UUID of the execution that enqueued this one (e.g. the request that enqueued a job), or nil. |
| `execution_preview` | Human label for the parent, e.g. `"GET /posts"` or `"PostsController#index"`. |
| `execution_stage` | Lifecycle stage active when the record was created (`middleware_before`, `action`, `render`, `middleware_after`, ...). |
| `user` | Resolved user id (`Subscribers::Users`), or nil. On a job, the id propagated from whatever enqueued it (see `job_attempt` below). |
| `tenant` | `Lantern.context(tenant: ...)` / `Context.current_tenant`, or nil. On a job, the tenant propagated from whatever enqueued it. |

## Parent records

`request`, `job_attempt`, `scheduled_task`, and `command` are the four
parent types (`Lantern::PARENT_TYPES`). Each opens an `Execution` and, in
addition to its own fields below, always carries (`Lantern.build_parent`,
`lib/lantern.rb`):

| Field | Meaning |
|---|---|
| `duration` | Wall time in microseconds, execution start to finish. |
| `stages` | Hash of stage name → microseconds spent in it (e.g. `{"middleware_before" => 120, "action" => 4300, "render" => 900}`). |
| `counters` | Hash of child-record counts for this execution — `queries`, `cached_queries`, `exceptions`, `logs`, `cache_events`, `jobs_enqueued`, `mail`, `broadcasts`, `notifications`, `outgoing_requests`, `storage_ops`, `view_renders`, `transactions`, `hydrated_models`, `lazy_loads`, `deprecations`, `spans` (`Execution::COUNTERS`). Counted even when the execution is sampled out, so aggregate rates don't depend on the sample rate. |
| `peak_memory` | RSS in bytes, sampled at most once per second process-wide (`Execution.sampled_memory`) — cheap enough to read but not per-execution-accurate to the microsecond. |
| `allocations` | Objects allocated during the execution (`GC.stat(:total_allocated_objects)` delta). |
| `gc_time` | GC time in the execution's window, when the Ruby build exposes `GC.stat(:time)`. |
| `exception_preview` | First unhandled exception's `"Class: message"`, truncated to 255 chars, or nil. |
| `context` | Serialized `Lantern.context(...)` key/values active for this execution, parameter-filtered like request params. `"_lantern_truncated": true` when it did not fit in 64KB. |

A sampled-out execution still ships its parent record if it raised an
unhandled exception (`Lantern.finish_execution`) — sampling controls
whether child records ship, not whether an error is visible.

### `request`

Built by the outermost Rack middleware (`lib/lantern/middleware/request.rb`),
which also owns the `middleware_before`/`action`/`render`/`middleware_after`
stage boundaries (the `action`/`render` boundaries come from
`start_processing.action_controller` and `render_template.action_view` in
`lib/lantern/subscribers/requests.rb`).

| Field | Meaning |
|---|---|
| `group` | Hash of `method` + route `pattern`. |
| `method` | HTTP verb. |
| `url` | Request origin + path, with authority credentials, the entire query string, and fragment removed, truncated to 2048 chars. |
| `path` | Request path. |
| `route` | Matched route pattern (`request.route_uri_pattern`), or `"unmatched"` for a 404. |
| `route_methods` | Array with the route's declared verb, if known. |
| `route_domain` | `request.host`. |
| `controller` | Controller name, `Controller` suffix stripped, underscored. |
| `action` | Action name. |
| `format` | Negotiated response format (`"html"`, `"json"`, ...). Empty when the request never reached a controller, since resolving it would mean parsing the request body at teardown. |
| `ip` | `request.remote_ip`. |
| `status_code` | Response status. |
| `request_size` / `response_size` | Bytes, from `Content-Length`. |
| `queue_time` | Microseconds the request waited in the proxy/web-server queue before the execution started, parsed from `X-Request-Start` (or `X-Queue-Start`): `t=1700000000.123` (seconds), `t=1700000000123` (ms), `t=1700000000123456` (µs), or the same values bare — the unit is decided by magnitude. A proxy clock running ahead clamps to `0`; anything over 60 seconds is treated as clock skew and dropped. nil when the header is absent or unparseable. |
| `view_runtime` / `db_runtime` | Milliseconds, from Action Controller's own `process_action.action_controller` payload. |
| `redirect_to` | Redirect target with authority credentials, the entire query string, and fragment removed, truncated to 512 chars, if `redirect_to` was called. This sanitizes telemetry only; it does not change the response's `Location` header. |
| `halted_callback` | Filter that halted the callback chain (`throw :abort`), if any. |
| `unpermitted_parameters` | Array of param keys strong parameters rejected. |
| `rate_limited` | `{name:, count:, to:}` if `ActionController::RateLimiting` fired, else nil. |
| `inertia` | Present only on an Inertia request (`X-Inertia` header or an Inertia render happened): `{component, version, partial_component, partial_only, partial_except, props_bytes, ssr_ms}`. `ssr_ms` is only set when `inertia_rails` SSR actually rendered this request (`lib/lantern/patches/inertia.rb`). |
| `headers` | Request headers as a hash, header names Title-Cased; values matching a redacted pattern replaced with `Redactor::FILTERED` (`lib/lantern/redactor.rb`). |
| `payload` | Filtered request params — only captured when `config.capture_request_payload` is on **and** the request raised an exception (never for successful requests). |
| `user_agent` | Truncated to 256 chars. |
| `files` | Array of `{name, size, content_type, error}` for each uploaded file in a multipart request (metadata only, never contents). A non-multipart request body is never parsed to fill this in. |
| `profiled` | `true` when a `profile` record shipped for this request; absent otherwise. |

### `job_attempt`

One per Active Job `perform` (`perform.active_job`,
`lib/lantern/subscribers/jobs.rb`), for jobs Solid Queue's own recurring
scheduler didn't originate (see `scheduled_task` below for the ones it did).

| Field | Meaning |
|---|---|
| `group` | Hash of the job class name. |
| `job_id` | Active Job's `job_id`. |
| `provider_job_id` | Queue adapter's own id (e.g. Solid Queue job row id). |
| `attempt_id` | This execution's id (same as `execution_id`). |
| `attempt` | `job.executions` — the retry count. |
| `name` | Job class name. |
| `queue` | Queue name. |
| `adapter` / `connection` | Queue adapter class, demodulized, `Adapter` suffix stripped (both fields carry the same value). |
| `concurrency_key` | If the job responds to `concurrency_key` (e.g. `good_job`/custom concurrency controls). |
| `priority` | Job priority. |
| `status` | `"processed"`, `"failed"`, `"aborted"`, or `"released"` (released = a `retry_on` caught the error internally — see `enqueue_retry.active_job` below). |
| `queue_latency` | Microseconds between `scheduled_at`/`enqueued_at` and this attempt starting. |
| `db_runtime` | Milliseconds of DB time during the attempt, from Active Job's own payload. |
| `arguments_preview` | Up to 10 arguments — GlobalID string for AR objects/GlobalID-capable arguments, class name otherwise (never raw argument values). Always on. |
| `arguments` | The job's real arguments (`job.serialize["arguments"]`, Active Job's own JSON-safe form, so an Active Record argument is already a GlobalID). Only present when `config.capture_job_arguments` is on — off by default, because arguments routinely carry PII. Hash arguments (including hashes nested in an array argument) go through the same parameter filter as request params, so a `password:` keyword ships as `[FILTERED]`. |
| `arguments_truncated` | `true` when trailing arguments had to be dropped to fit `arguments` into 8 KiB of JSON. Absent otherwise, and absent entirely when `capture_job_arguments` is off. |
| `profiled` | `true` when a `profile` record shipped for this attempt; absent otherwise. |

`user` and `tenant` on a job attempt (and therefore on every child record
under it) come from the execution that enqueued the job, not from the
worker process, which usually has no signed-in user to resolve.
`JobTracing#serialize` puts the enqueuing execution's resolved user id and
tenant into the Active Job payload as `lantern_user`/`lantern_tenant`,
alongside `lantern_trace_id`/`lantern_parent_id`; `perform_start` restores
them onto the job's execution before its first record is built. Details
worth knowing:

- **Identifiers only.** Two strings — the same tenant-prefixed id the
  `user` record carries, and the tenant name. No user or tenant model is
  serialized, hydrated, or looked up, on either side.
- **Jobs enqueuing jobs.** A job serializes the values it was given, so a
  chain of jobs keeps the identity of the request that started it.
- **Retries and scheduled jobs.** A retry re-enqueues the same job object,
  and Active Job re-serializes it, so every attempt keeps the original
  identity. `perform_later(wait:)`/`set(wait_until:)` serialize at enqueue
  time like any other job — a job scheduled for next week is attributed to
  whoever scheduled it. Solid Queue's recurring scheduler enqueues nothing
  on anyone's behalf, so a `scheduled_task` has no propagated user and
  falls back to local resolution (normally nil).
- **Nothing to propagate.** The keys are omitted from the payload when
  there is no user or tenant, and a payload without them (one enqueued by
  an older version of the gem, still sitting in a queue through a deploy)
  deserializes to nil and falls back to `Users.resolve_from_current`,
  exactly as before. Inline `perform_now` never serializes, so it resolves
  locally too.
- **A propagated user does not emit a `user` record.** The worker skips
  local resolution, and it is resolution that emits the name/email record.
  The enqueuing process already emitted it for that id.
- **Cardinality.** The user id is one more high-cardinality dimension on
  every job record. Apps that do not want a user attached to jobs at all
  can return nil from `config.user` for the cases they care about — the
  propagation only ever carries what that resolver already produced.

Also has a special case with no `Execution`: **Solid Queue pruned jobs**
(`fail_many_claimed.solid_queue`) never reach `perform.active_job` because
their worker was killed or reaped. Each gets its own throwaway execution
and reports `job_attempt` with `job_id: nil`, `name: "(pruned)"`,
`status: "failed"`, `duration: 0`, and `exception_preview` set to the
pruning error, truncated to 255 chars.

### `scheduled_task`

Same `perform.active_job` subscriber as `job_attempt`, but for a job
Solid Queue's `RecurringExecution` table shows was triggered by
`config/recurring.yml` rather than an ad hoc enqueue (`recurring_task_key`,
`lib/lantern/subscribers/jobs.rb`). Carries every `job_attempt` field
above, plus:

| Field | Meaning |
|---|---|
| `task_key` | The `config/recurring.yml` key. |
| `group` | Hash of the task key (not the class name). |
| `schedule` | The task's configured schedule string (e.g. `"every day at 3am"`), looked up from `SolidQueue::RecurringTask`, refreshed at most once per 60s. |
| `drift` | Microseconds between the task's scheduled `run_at` and when this attempt actually started. |

### `command`

One per top-level `bin/rails runner` invocation or Rake task invocation
(prerequisites nest inside the same command instead of opening their own —
see `lib/lantern/patches/rake_task.rb`'s comment on `Rake::Task#invoke`
vs `#execute`). `db:migrate` and other tasks in
`Configuration::DEFAULT_VENDOR_COMMANDS` are skipped unless
`config.capture_default_vendor_commands` is on.

| Field | Meaning |
|---|---|
| `group` | Hash of the task/command name. |
| `class` | `"Rake::Task"` or `"Rails::Command::RunnerCommand"`. |
| `name` | Task name, or `"runner"`. |
| `command` | Full invocation, e.g. `"rake db:seed[foo]"` or `"rails runner SomeScript.run"`. |
| `exit_code` | 0 on success, `SystemExit`'s status, or 1 on an unhandled exception, clamped to 0-255. |
| `interactive` | `true` on a `bin/rails runner` an engineer typed or piped (`-`, inline code, or a `.rb` file under `config.interactive_runner_paths`); absent otherwise. Such a run ships this record — with its `exit_code` and `exception_preview` — but its exception is not reported. A deployed script (`rails runner script/nightly.rb`), a rake task, and a job are never interactive. See [Console and runner sessions](replacing-sentry.md#console-and-runner-sessions). |

### `channel_action`

One parent per Action Cable channel action. Lantern opens it before
`perform_action.action_cable` invokes application code and closes it after the
action returns or raises, so the SQL, logs, broadcasts, transmits, and
exceptions inside share one trace — an Action Cable action has no HTTP request
and no Rack middleware around it, so without this they had no parent at all.

| Field | Meaning |
|---|---|
| `group` | Hash of channel class + action. |
| `channel` | Channel class name, e.g. `ChatChannel`. |
| `action` | Invoked channel action name. |
| `status` | `"processed"` or `"failed"`. |
| `failed` | Whether the action raised. |

Sampling uses `sample[:channels]` / `LANTERN_CHANNEL_SAMPLE_RATE`. An
unhandled channel exception is still eligible for exception sampling and ships
with this parent even when the channel sample rate is zero.

## Child records

### `query`

Every non-cached `sql.active_record` notification except `SCHEMA`,
`TRANSACTION`, and `EXPLAIN` statements (`lib/lantern/subscribers/queries.rb`).
The hottest record type in the gem — built as one hash literal rather than
going through `Lantern.record`.

| Field | Meaning |
|---|---|
| `_group` | Hash of the normalized SQL shape + adapter + connection (`SqlNormalizer`). |
| `sql` | Raw SQL text, truncated to 16,384 chars. |
| `name` | ActiveRecord's own query name (e.g. `"User Load"`). |
| `duration` | Microseconds. |
| `connection` | Database config name (e.g. `"primary"`). |
| `role` | Multi-DB role the connection was checked out for: `"writing"` or `"reading"`. |
| `adapter` | `"sqlite"`, `"postgresql"`, etc. |
| `async` | Whether this was an async query (`load_async`). |
| `row_count` | Rows returned, when the adapter reports it. |
| `affected_rows` | Rows affected (writes), when the adapter reports it. |
| `in_transaction` | Whether an open transaction wrapped this statement. |
| `source` | App-code call site that issued the query (`Backtrace.caller_location`) — resolved once per query shape per process, not per query, except when the query is slow (`config.slow_query_threshold_ms`), where it's always resolved fresh. |
| `allocations` | Ruby object allocations for this query (`event.allocations`). |
| `explain` | The adapter's own query plan (Postgres `EXPLAIN`, SQLite `EXPLAIN QUERY PLAN`, ...), truncated to 4000 chars, or nil. Only when `config.capture_query_explain` is on, the statement is a `SELECT`, and it took at least `config.explain_threshold_ms`; then at most once per query shape per process per 10 minutes. The EXPLAIN runs on the same connection the query used, with Lantern paused, so it never becomes a `query` record of its own. |

A cached query (`payload[:cached]`) only increments the execution's
`cached_queries` counter — it never becomes a `query` record.

### `n_plus_one`

Fired once per query group when its count within the current execution
crosses `config.n_plus_one_threshold` (`lib/lantern/subscribers/queries.rb`)
— not on every repeat, just the crossing.

| Field | Meaning |
|---|---|
| `group` | Same group hash as the triggering `query` record. |
| `sql` | Normalized (parameter-stripped) SQL shape, truncated to 2048 chars. |
| `count` | How many times this group had run in the execution when the threshold was crossed. |
| `source` | App-code call site. |

### `transaction`

One per `transaction.active_record` (`lib/lantern/subscribers/queries.rb`).

| Field | Meaning |
|---|---|
| `group` | Hash of connection name + outcome. |
| `duration` | Microseconds. |
| `outcome` | `"commit"`, `"rollback"`, etc. (`payload[:outcome]`). |
| `connection` | Database config name. |
| `statement_count` | Number of `sql.active_record` statements counted against this transaction object while it was open. |

### `exception`

Every error that reaches `Rails.error` (handled or not), plus anything
the request middleware or command patches catch directly, plus anything a
controller swallows with `rescue_from`
(`lib/lantern/subscribers/exceptions.rb`). Standalone-capable — reports
even with no execution open (console, boot). Deduplicated per error
object, execution, and handled/unhandled disposition, so Rails.error plus
outer middleware report a re-raised error only once without suppressing the
same object when it is reused in another execution. A capture discarded by
sampling or `Lantern.pause` does not mark the object as seen. Unhandled
exceptions bypass the execution buffer: `Lantern.record_now` enqueues the
record and wakes the in-memory reporter immediately, without network I/O on
the application thread. This improves the chance of delivery before a normal
exit but is not a durable crash spool; a hard kill, OOM, or exit after the
shutdown deadline can lose the record.

| Field | Meaning |
|---|---|
| `group` | Hash of this record's `fingerprint` parts. |
| `fingerprint` | The parts that were hashed, up to 10 strings of 200 chars each — by default class + top in-app frame's file/line + normalized message. Always present, so the platform can show *why* an occurrence grouped where it did. |
| `fingerprint_source` | Where the fingerprint came from: `"default"`, `"report"` (`Lantern.report(error, fingerprint: [...])`), `"error"` (the exception's own `#lantern_fingerprint`), or `"resolver"` (a `Lantern.fingerprint { }` block). |
| `class` | Exception class name. |
| `message` | Truncated to 4096 chars. |
| `handled` | Whether the error was rescued (`Rails.error.handle`) vs. unhandled (`Rails.error.report`/escaped). |
| `severity` | `:error`/`:warning`/etc., as a string. |
| `source` | Free-text source tag the raiser passed, e.g. `"application.active_job"`, `"application.action_cable"` (a channel action that raised), `"lantern.middleware"`, `"action_controller.rescue_from"`, or `"browser"` for a JavaScript error (see below). |
| `file` / `line` | Top in-app backtrace frame. |
| `frames` | Full backtrace (`Backtrace.frames`), each frame optionally with source snippet lines if `config.capture_exception_source` is on. Read from `backtrace_locations`, or parsed from the String backtrace when that is nil (an exception whose backtrace was assigned with `set_backtrace` or delegated to a wrapped error, as `ActiveRecord::StatementInvalid` and `Faraday::Error` do). |
| `cause` | `{class, message}` of `error.cause`, truncated, or nil. |
| `context` | Serialized `Lantern.context(...)` active when the error was captured. |
| `code` | `Errno` constant, or `error.errno`/`error.code` if the error exposes one. |
| `sql_state` | Postgres SQLSTATE, for `ActiveRecord::StatementInvalid` wrapping a driver error that exposes one (not populated for SQLite). |
| `ruby_version` / `rails_version` | Process versions. |

A handled exception on a sampled-out execution is dropped entirely
(matching everything else); an *unhandled* one still ships, governed by
its own `exceptions` sample rate rolled once per execution
(`exception_sampled?`).

The default fingerprint normalizes the message before hashing it, so one
issue doesn't shatter into thousands: URLs, email addresses, UUIDs, ISO
timestamps, IPv4 addresses, quoted strings, hex runs of six characters or
more, and plain integers all become `?`, whitespace collapses, and the
result is cut at 200 chars. For classes whose message is mostly the data
that varied, only the message *prefix* is kept — up to the first `:` for
`ActiveRecord::RecordNotFound`, `ActiveRecord::RecordInvalid`, `KeyError`,
`ArgumentError`, and `TypeError`, up to the first `for ` for
`NoMethodError` and `NameError` — so `key not found: :order_id` and `key
not found: :user_id` are one issue rather than two. Override any of it
with `Lantern.fingerprint`, `#lantern_fingerprint`, or
`Lantern.report(error, fingerprint: [...])`; see
[`docs/configuration.md`](configuration.md).

An error whose class — or any named ancestor of it — appears in
`config.ignored_exceptions` is never captured at all, handled or not.
An error a controller rescues with `rescue_from` is captured as
`handled: true`, `severity: "warning"`, `source:
"action_controller.rescue_from"`, from Rails'
`rescue_from_callback.action_controller` notification; set
`config.capture_rescued_exceptions = false` to turn that off. Active Job's
equivalents (`retry_on` exhausted, `discard_on`) are already covered by
the `retry_stopped`/`discard` subscriptions in
`lib/lantern/subscribers/jobs.rb`. See
[`docs/configuration.md`](configuration.md) for both settings.

#### Browser errors (`source: "browser"`)

Every JavaScript error the browser client catches — `window.onerror`,
unhandled promise rejections, Inertia's failed-request events (`exception`
and `invalid` on Inertia 2, `networkError` and `httpException` on 3),
and anything the app reports itself with `reportError` — arrives on the
same beacon as visits (`POST /lantern/beacon`, 50 errors per beacon at
most) and is recorded as an ordinary `exception`: `source: "browser"`,
`handled: false`, `severity: "error"`, `class` set to the JavaScript
error's `name`, `message` truncated to 1024 chars. It carries the same
envelope every other record does, including `deploy`, so a browser issue
regresses with a release exactly like a Ruby one.

The browser's stack (8192 chars at most) is parsed into the same frame
shape a Ruby backtrace produces — V8's `at fn (url:line:col)` and
SpiderMonkey/JavaScriptCore's `fn@url:line:col` are both understood, and a
line with no location on it is dropped:

| Frame key | Meaning |
|---|---|
| `file` | Path relative to the app's own origin (`assets/index-Bq1x9K.js`, `app/frontend/pages/orders/index.tsx`), or the whole URL for a script served from anywhere else. Any query string is cut. |
| `line` | Line number. Columns are parsed but not stored. |
| `function` | The function name the engine gave, or `"(anonymous)"`. |
| `in_app` | True when the script came from the app's own origin and is not under `node_modules/` or `vendor/`. |

No source snippets: the file is on the client, not on the server. Frames
are fingerprinted exactly like Ruby ones — class, top in-app frame, and
the normalized message — so browser errors group, split, merge, resolve,
and regress through the same Issue machinery.

`context` carries a `browser` key with the page `url`, the Inertia
`component`, the `visit` the error happened in (if any), the tab's
`session` id, the `user_agent`, and up to 20 `breadcrumbs`
(`{at, kind, text}`, `kind` being `console`, `click`, or `navigate`) — the
trail the client recorded before the crash. Anything the app passed as
`reportError(error, context)` is merged in alongside it, flattened to
strings, 20 keys at most.

### `cache_event`

Every `cache_*.active_support` notification except the inner read inside
a `fetch` (`lib/lantern/subscribers/cache.rb`). Vendor cache key prefixes
(rack-attack, flipper, solid_cable, by default) are skipped unless
`config.capture_default_vendor_cache_keys` is on; keys matching
`config.ignored_cache_key_prefixes` are always skipped.

| Field | Meaning |
|---|---|
| `_group` | Hash of store class + key shape (digits/long-hex stripped so `"users/123"` and `"users/456"` share a group). |
| `store` | Cache store class, demodulized. |
| `key` | Truncated to 255 chars. |
| `type` | `"hit"`, `"miss"`, `"read_multi"`, `"generate"`, `"write"`, `"write_multi"`, `"delete"`, `"delete_multi"`, `"delete_matched"`, `"increment"`, `"decrement"`, `"exist"`, or `"fail"` when the store raised. |
| `duration` | Microseconds. |
| `ttl` | Seconds, from `expires_in`, or 0. |
| `hits` | Count of hits, for a `read_multi`. |

### `mail`

`deliver.action_mailer` (`lib/lantern/subscribers/mail.rb`).

| Field | Meaning |
|---|---|
| `group` | Hash of the mailer class name. |
| `mailer` | Mailer class name. |
| `subject` | Truncated to 255 chars. |
| `to` / `cc` / `bcc` | Recipient **counts**, not addresses. |
| `attachments` | Attachment count. |
| `delivery_method` | E.g. `"SMTP"`, `"Test"`. |
| `perform_deliveries` | Whether delivery actually ran (`perform_deliveries` wasn't disabled). |
| `duration` | Microseconds. |
| `failed` | Whether an exception occurred during delivery. |
| `message_id` | Truncated to 255 chars. |

A mailer's own template render is a separate `view_render` record (see
below) via `process.action_mailer`, `kind: "mailer"`.

### `broadcast`

Action Cable broadcast/transmit/perform, which also covers Turbo Streams
and `inertia_cable` since both go through `broadcast.action_cable`
(`lib/lantern/subscribers/broadcasts.rb`). Three sub-shapes share the type:

| Field | Present for | Meaning |
|---|---|---|
| `kind` | all | `"broadcast"`, `"transmit"`, or `"perform_action"`. |
| `group` | all | Hash of stream shape (broadcast) or channel class (+ action). |
| `stream` | broadcast | Broadcasting name, ids stripped, truncated to 255 chars. |
| `bytes` | broadcast, transmit | Payload size. |
| `coder` | broadcast | Serializer class name. |
| `channel` | transmit, perform_action | Channel class name. |
| `via` | transmit | How the transmit happened (`payload[:via]`), truncated to 255 chars. |
| `action` | perform_action | Channel action name. |
| `failed` | perform_action | `true` when the action raised; the exception itself is reported separately with source `"application.action_cable"`. |
| `duration` | all | Microseconds. |

### `notification`

Noticed gem deliveries only (`lib/lantern/subscribers/notifications.rb`)
— tagged by hooking the same `perform.active_job` event the `job_attempt`
subscriber uses, filtered to jobs whose class starts with `Noticed::`.
No-ops entirely if the `noticed` gem isn't loaded.

| Field | Meaning |
|---|---|
| `group` | Hash of the Noticed delivery job's class name. |
| `notifier` | The `notification_class` from the job's first argument, if present. |
| `channel` | Delivery class with `Delivery` stripped and lowercased, e.g. `"email"`, `"slack"`. |
| `delivery_method` | Delivery job class, demodulized (e.g. `"EmailDelivery"`). |
| `duration` | Microseconds. |
| `failed` | Whether the delivery job raised. |

### `outgoing_request`

Any `Net::HTTP#request` call (covers Faraday's default adapter, HTTParty,
RestClient, most of the HTTP ecosystem — `lib/lantern/patches/net_http.rb`),
plus Faraday connections that explicitly add `Lantern::Faraday` middleware
(`lib/lantern/faraday.rb`, for apps using a non-default Faraday adapter).
Requests to Lantern's own ingest URL are always skipped so shipping
telemetry never generates telemetry about itself. A Faraday connection
using the default (Net::HTTP) adapter defers to the Net::HTTP patch via a
thread-local reentry flag, so it's never double-recorded.

| Field | Meaning |
|---|---|
| `group` | Hash of host + method. |
| `host` | Request host. |
| `method` | HTTP verb. |
| `url` | Scheme + host + path, with authority credentials, the entire query string, and fragment removed, truncated to 2048 chars. |
| `duration` | Microseconds. |
| `status_code` | Response status, 0 if the request errored before a response. |
| `request_size` | Bytes (Net::HTTP path only). |
| `response_size` | Bytes, from `Content-Length` or body size. |
| `error` | `"Class: message"`, truncated to 255 chars, if the request raised. |
| `response_body` | First 4 KiB of the response body, but only when `config.capture_response_body_on_error` is on (off by default) *and* the response was an error. A body that parses as a JSON object is run through the same parameter filter as request params and re-serialized; anything else is stored as it arrived. nil in every other case — including a connection failure, where there is no response (on the Net::HTTP path a body is read only if Net::HTTP already buffered it, so a response being streamed through `read_body` is never consumed; on the Faraday path the body is taken only once a status came back, so an outgoing request payload can never be filed as a response). |
| `source` | App-code call site (Net::HTTP path only). |

### `storage_op`

Every Active Storage service operation
(`lib/lantern/subscribers/storage.rb`): upload, download, streaming
download, delete, delete_prefixed, exist, url, update_metadata, analyze,
transform, preview.

| Field | Meaning |
|---|---|
| `group` | Hash of service name + op. |
| `service` | Active Storage service name. |
| `op` | Operation, `service_` prefix stripped (e.g. `"upload"`, `"analyze"`). |
| `key` | Blob key, truncated to 255 chars. |
| `duration` | Microseconds. |
| `exist` | For `exist` ops, whether the blob existed. |

### `view_render`

Template, partial, layout, and collection renders
(`lib/lantern/subscribers/views.rb`), plus mailer template renders
(`process.action_mailer`, `lib/lantern/subscribers/mail.rb`, `kind:
"mailer"`). Only the first `config.max_view_renders_per_execution` per
execution are stored as records — all are still counted toward the
parent's `view_renders` counter regardless of the cap.

| Field | Meaning |
|---|---|
| `group` | Hash of the template identifier. |
| `identifier` | Template path, app-root prefix stripped, truncated to 255 chars. Mailer renders use `"Mailer#action"` instead. |
| `kind` | `"template"`, `"partial"`, `"layout"`, `"collection"`, or `"mailer"`. |
| `layout` | Layout name, for a `render_layout` event. |
| `count` | Item count, for a `render_collection` event. |
| `cache_hits` | Fragment cache hits, for a `render_collection` event. |
| `duration` | Microseconds. |

### `span`

Custom timing around any block of app code
(`Lantern.span(name, **attributes) { ... }`, `lib/lantern.rb`). Returns
the block's value untouched and is a no-op wrapper — it still yields —
when Lantern is disabled, nothing is executing, or the execution isn't
recording. Every span also increments the parent's `spans` counter.

```ruby
Lantern.span("pdf.render", template: "invoice", pages: 12) { renderer.call }
```

| Field | Meaning |
|---|---|
| `group` | Hash of the span name. |
| `name` | Span name, truncated to 255 chars. |
| `duration` | Microseconds. |
| `attributes` | Up to 25 keys; values stringified (`inspect` for anything that isn't already a String), truncated to 200 chars, and run through the same parameter filter as request params and exception locals — so a `password:` attribute ships as `[FILTERED]`. nil when the call passed no attributes. |
| `status` | `"ok"`, or `"failed"` if the block raised — the exception is recorded and then re-raised untouched. |

### `attachment`

An arbitrary blob filed against an execution and, optionally, an exception
(`Lantern.attach(name, data, content_type:, exception:)`,
`lib/lantern/attachments.rb`) — the payload that failed to parse, a
rendered PDF, the webhook body a customer swears they sent. Sentry's
`Sentry.add_attachment` equivalent.

```ruby
Lantern.attach("payload.json", request.raw_post)
Lantern.attach("invoice.pdf", Rails.root.join("tmp/invoice.pdf"))
Lantern.attach("payload.json", body, exception: error)
Lantern.report(error, attachments: { "payload.json" => body })
```

`data` may be a String (the bytes themselves), a `Pathname` (the file is
read), or any IO. This is one of the standalone types
(`Lantern::STANDALONE_TYPES`): inside a recording execution it ships as a
child of it, and with nothing executing — a boot hook, a console, a rescue
outside any request — it ships on its own. Returns nil and records nothing
when Lantern is disabled or the payload is empty.

| Field | Meaning |
|---|---|
| `group` | Hash of the attachment name, so the same name across occurrences buckets together. |
| `name` | Attachment name, truncated to 255 chars. |
| `content_type` | Passed explicitly, else guessed from the name's extension via Marcel (which Rails already ships for Active Storage), else `application/octet-stream`. Truncated to 128 chars. |
| `bytes` | Size of the payload **as stored**, i.e. after any truncation — not the size of the original. |
| `data` | `Base64.strict_encode64(Zlib.gzip(bytes))`, so a text payload costs a fraction of its size in the batch. |
| `truncated` | `true` when the payload was longer than `config.max_attachment_bytes` (default 1 MiB) and was cut to the cap. Absent otherwise. |
| `exception_group_hash` | The `_group` of the `exception` record this attachment belongs to, when one was passed as `exception:` — the same hash `Subscribers::Exceptions` files that error under, so the platform can show the attachment on the issue. nil otherwise. |

### `log`

Two independent sources feed this type (`lib/lantern/subscribers/logs.rb`):
`Rails.logger` lines, captured by broadcasting to a `Logger` subclass
that intercepts every `add` call, and Rails 8.1's structured
`Rails.event` framework events. Lines matching Rails' own per-request/job
noise (`"Started GET"`, `"Processing by"`, `"Rendered"`, etc. — already
covered by the `request`/`job_attempt` records) are dropped, as are lines
below `config.log_level` and Lantern's own `[lantern]`-prefixed debug
output. Framework structured events (`action_controller.*`,
`active_record.*`, etc.) are dropped unless `config.capture_framework_events`
is on, for the same reason.

| Field | Meaning |
|---|---|
| `level` | `"debug"`/`"info"`/`"warn"`/`"error"`/`"fatal"`/`"unknown"` for a logger line, `"event"` for a structured event. |
| `message` | Logger line text (ANSI color codes stripped), or the event name, truncated to 8192 chars. |
| `tags` | Active `Rails.logger.tagged` tags, for a logger line; the event's own tags, for a structured event. |
| `context` | Serialized `Lantern.context(...)`, for a logger line; the event payload as JSON (truncated to 8192 chars), for a structured event. |
| `source` | File:line the structured event fired from, when available (structured events only). |

### `enqueued_job`

`enqueue`/`enqueue_at`/`enqueue_all.active_job`
(`lib/lantern/subscribers/jobs.rb`) — one record per job enqueued, distinct
from `job_attempt`/`scheduled_task` which record the later `perform`.

| Field | Meaning |
|---|---|
| `group` | Hash of the job class name. |
| `job_id` | Active Job's `job_id`. |
| `name` | Job class name. |
| `queue` | Queue name. |
| `adapter` | Queue adapter class, demodulized. |
| `priority` | Job priority. |
| `scheduled_at` | Unix timestamp, for a delayed enqueue. |
| `duration` | Microseconds spent in the enqueue call itself. |
| `failed` | Whether enqueuing itself failed (an exception during enqueue, or `successfully_enqueued?` returning false). |

### `user`

Standalone — emitted once per distinct user id per process-hour
(`lib/lantern/subscribers/users.rb`), not per request, so the platform
can show names/emails without every other record carrying them. Resolved
via `config.user` block if set, else `Current.user` (authentication-zero
/ Rails 8 auth generator), else Warden (Devise).
The process-hour cache entry is written only once the execution carrying
the entity has been handed to the reporter, so a sighting that was sampled
out or paused does not suppress the next sighting that would ship. Forked
workers start with an empty cache.

| Field | Meaning |
|---|---|
| `id` | Resolved user id, tenant-prefixed (`"tenant:id"`) if `Lantern.context(tenant:)` is set. |
| `name` | Truncated to 255 chars. |
| `email` | Truncated to 255 chars. |
| `tenant` | Current tenant context, if any. |

### `deprecation`

`deprecation.rails` (`lib/lantern/subscribers/deprecations.rb`).

| Field | Meaning |
|---|---|
| `group` | Hash of gem name + first 120 chars of the message. |
| `message` | Truncated to 2048 chars. |
| `gem_name` | Gem the deprecation came from. |
| `horizon` | Deprecation horizon version string. |
| `source` | First app-code frame in the deprecation's callstack, app-root prefix stripped. |

### `visit`

Standalone — Inertia page-visit timing reported by the browser client
(`app/frontend/lib/lantern.ts`, generated by `lantern:install`), POSTed
to `POST /lantern/beacon` and recorded server-side by
`Lantern::BeaconController` (`app/controllers/lantern/beacon_controller.rb`).
Batched client-side (flushed every 5s, on `pagehide`, or once 20 visits
queue up) and capped at 50 visits per beacon request. No-ops entirely if
`config.beacon_enabled` is off.

| Field | Meaning |
|---|---|
| `group` | Hash of the Inertia component name. |
| `component` | Truncated to 255 chars. |
| `url` | Truncated to 2048 chars. |
| `method` | Truncated to 10 chars. |
| `duration` | Microseconds, client-measured (`Date.now()` start to `finish`). |
| `status` | `"success"`, `"error"`, or `"cancelled"` (visit was superseded before finishing). |
| `partial` | Whether this was a partial Inertia reload (`only`/`except` present). |
| `only` | Up to 50 prop keys, for a partial reload. |
| `props_bytes` | Serialized prop payload size, client-measured. |
| `lcp` | Largest Contentful Paint, integer ms, clamped to 0–120000. Initial load only. |
| `cls` | Cumulative Layout Shift — the largest session window, float rounded to 4 decimals, clamped to 0–100. Initial load only. |
| `inp` | Interaction to Next Paint, integer ms, clamped to 0–120000. The slowest interaction, not the spec's high percentile. Initial load only. |
| `ttfb` | Time to First Byte from navigation timing's `responseStart`, integer ms, clamped to 0–120000. Initial load only. |
| `user` | Resolved server-side from the beacon request's session/cookies, same resolver as every other record. |
| `tenant` | Current tenant context. |
| `user_agent` | Truncated to 256 chars. |

The **initial page load** is reported as a visit too, even though Inertia
never routed it: `method` `"GET"`, `status` `"success"`, `component` read
from the Inertia root's `#app[data-page]` JSON, and `duration` taken from
navigation timing (`loadEventEnd` or `responseEnd`, minus `startTime`).
It is the only visit that carries the four Core Web Vitals, and it is held
back until the page is first hidden (`visibilitychange`/`pagehide`) so
those numbers are final when it ships. Every vital is nil on a browser
that doesn't support the `PerformanceObserver` entry type behind it.

### `session`

Standalone — one session of the monitored app, for release health. The
`deploy` on the envelope *is* the release; the platform counts sessions per
deploy and reports crash-free rates from them. Two sources produce the same
record:

- **Browser** (`source: "browser"`). The client (`app/frontend/lib/lantern.ts`)
  mints a 16-hex id per tab in `sessionStorage` (key `lantern.session`, so it
  dies with the tab), mirrors it into a `lantern_session` cookie, and sends it
  with every beacon flush. `Lantern::BeaconController` writes at most one
  `session` record per flush: the first (no `duration_ms` yet) opens the
  session, later ones beat it along, and the `pagehide`/`visibilitychange`
  flush closes it with `ended`.
- **Server** (`source: "server"`). `lib/lantern/sessions.rb` aggregates, per
  process, every request that resolves a user or carries that cookie (or an
  `X-Lantern-Session` header), and a background thread ships one record per
  session every `config.session_flush_interval` (default 60s). A session idle
  for `config.session_timeout` (default 30 minutes) ships with `ended` and is
  dropped. At most 10,000 keys are tracked per process; past that the oldest
  is dropped and counted in `Lantern::Sessions.dropped`.

Both are off when `config.track_sessions` is false, and both key on the same
id when the browser cookie is present, so the platform dedupes the two halves
of one session rather than counting it twice.

| Field | Meaning |
|---|---|
| `group` | Hash of the session key. |
| `id` | Session key, truncated to 64 chars: the browser client's id, else `"user:<user_id>"`. |
| `source` | `"browser"` or `"server"`. |
| `status` | `"started"` (opened, no duration yet), `"ok"`, `"errored"` (a 5xx or a handled exception), or `"crashed"` (an unhandled exception). Server sessions only escalate. |
| `started_at` | Unix seconds (float) the session began — `timestamp` is when the record was flushed, not when the session started. |
| `duration` | Microseconds from `started_at` to the last request/visit, nil on the record that opens the session. |
| `requests` | Requests in this session so far (server only). |
| `visits` | Inertia visits in this beacon flush (browser only). |
| `errors` | Requests that 5xx'd or raised (server), or visits with status `"error"` in this flush (browser). |
| `ended` | Whether this is the session's last record. |
| `user` | Resolved user id, when there is one. |

### `process`

Standalone — one per process boot (`lib/lantern/subscribers/process_info.rb`),
fired unconditionally during subscriber installation, not gated on
sampling. Gives the platform a server/deploy inventory for free.

| Field | Meaning |
|---|---|
| `pid` | Process id. |
| `role` | `"web"` (Puma present), `"worker"` (Solid Queue supervisor, `$PROGRAM_NAME` includes `"jobs"`), `"console"`, `"command"` (`$PROGRAM_NAME` ends in `rake`), or `"process"`. |
| `ruby_version` / `rails_version` / `lantern_version` | Versions. |
| `app` | Top-level module name of the Rails app. |
| `environment` | `config.environment_name` (defaults to `Rails.env`). |
| `boot_seconds` | Monotonic time since `Lantern::BOOTED_AT` (this file's load time, i.e. as early in boot as the gem can observe). |
| `database_adapter` | Primary DB adapter name. |
| `queue_adapter` | Active Job queue adapter name. |
| `cache_store` | `Rails.cache` class name. |

### `health`

Standalone — one every `config.health_interval` seconds (default 15) from
a single background thread per process (`lib/lantern/health.rb`), started
by the engine's `lantern.health` initializer only when Lantern is enabled,
the process `role` is `"web"` or `"worker"`, and the Rails env isn't
`test`. This is the gem's only *sampled gauge*: everything else is an
event, this is a periodic snapshot of how loaded the process is.

The whole sample runs inside `Lantern.ignore` and rescues everything, so a
missing constant, an unmigrated queue database, or a checkout timeout
degrades each field to nil instead of raising on a thread nobody watches —
the record still ships with whatever it did manage to read.

| Field | Meaning |
|---|---|
| `pid` | Process id. |
| `role` | Same detection as `process` above: `"web"` or `"worker"`. |
| `memory` | RSS in bytes (`Execution.sampled_memory`). |
| `threads_max` | Puma's configured max threads, or nil when Puma isn't running. |
| `threads_busy` | Puma threads currently serving a request (`busy_threads`). |
| `backlog` | Requests queued inside Puma waiting for a thread. |
| `pool_size` | Active Record connection pool size (`connection_pool.stat[:size]`). |
| `pool_busy` | Connections checked out. |
| `pool_waiting` | Threads blocked waiting for a connection — sustained non-zero means the pool is undersized for the thread count. |
| `queue_depth` | `SolidQueue::ReadyExecution.count` — jobs ready to run right now. |
| `queue_latency` | Microseconds since the oldest ready job was created, i.e. the backlog's head-of-line wait. nil when the queue is empty. |
| `detail` | JSON string: `queues` (ready count per queue name), `workers` (`SolidQueue::Process` rows of kind `Worker`), `requests_count` (Puma's lifetime request count for this process), `running` (threads Puma has spawned), `max_threads_reached` (true when Puma's `pool_capacity` was 0 at sample time, i.e. no spare thread). |

Every Puma field is nil when no `Puma::Server` exists in the process, and
every Solid Queue field is nil when `SolidQueue` isn't loaded.

The sampler re-arms itself after `fork` (a `Process._fork` hook), so
clustered Puma workers and forked Solid Queue workers each report without
any `on_worker_boot` configuration.

`Lantern::Health.start!` is idempotent, and `stop!` (registered by the
engine's `at_exit`, ahead of the reporter's final flush) wakes the thread
off its `ConditionVariable` immediately rather than waiting out the
interval.

### `profile`

A sampling profile of one execution (`lib/lantern/profiler.rb`,
`Lantern.start_profile`/`ship_profile` in `lib/lantern.rb`). Off by
default; see `docs/configuration.md`'s **Profiling** section for how an
execution is picked and which backend gem the app has to install. Exactly
one `profile` per execution, buffered as a child of that execution and
shipped with it, and the execution's parent record then carries
`profiled: true`.

| Field | Meaning |
|---|---|
| `profiler` | `"vernier"` or `"stackprof"` — the backend that collected it. |
| `mode` | `"wall"`. |
| `interval` | Sampling interval in microseconds (`config.profile_interval_us`). |
| `duration` | Microseconds actually profiled, start to stop. |
| `samples` | Total samples collected. When `stacks` was truncated (below), the counts inside it sum to less than this. |
| `stacks` | Base64 of gzip of the collapsed-stack text, described below. |
| `stacks_bytes` | Uncompressed size of that text, in bytes. |

`stacks` decodes to *folded stacks*, the same shape Brendan Gregg's
`stackcollapse` produces: one line per unique stack, outermost frame
first, semicolon-separated, then a space and the number of samples that
landed on it.

```
<main> (config.ru:3);WidgetsController#index (app/controllers/widgets_controller.rb:4);ActiveRecord::Relation#each (activerecord-8.1.0/lib/active_record/relation/delegation.rb:89) 37
```

Each frame is `Class#method (path:line)`. The Rails root is stripped from
app paths, an installed gem's path becomes `<gem>/relative/path` (the
version is dropped; the deploy already records it), Ruby's own library
becomes `ruby/...`, and a C function — which has no Ruby file of its own —
reads `<cfunc>:0`.
Lines are ordered by sample count descending, ties broken by the stack
text, so the same profile always serialises to the same bytes.

The text is capped at **4 MiB uncompressed**
(`Lantern::Profiler::MAX_COLLAPSED_BYTES`); past that the least frequent
stacks are dropped, since the shape of a profile lives in its frequent
ones. Rails stacks are deep enough that a busy request can reach the cap,
which is why `samples` is reported separately from the counts in `stacks`.

Both backends are process-global — there is one profiler per process, not
one per thread — so an execution that starts while another is being
profiled simply isn't profiled (counted in `Lantern::Profiler.skipped`).
Vernier samples every thread in the process, so only the thread that
started the profile is folded in; StackProf samples wherever its `SIGPROF`
lands.
