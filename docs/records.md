# Record types

Every record Railwatch ships is a flat hash. See `lib/railwatch/record.rb`.
This lists all 28, field by field, sourced from the subscriber or patch
that builds each one. Field names below are the hash keys as sent over
the wire: symbols in Ruby, strings in the gzip NDJSON payload.

## Shared envelope

Every record carries these fields, from `Record.build` in
`lib/railwatch/record.rb`:

| Field | Meaning |
|---|---|
| `v` | Record schema version for this type (`Record::VERSIONS`). |
| `t` | Type string, e.g. `"query"`. |
| `timestamp` | Unix seconds (float) when the event started. |
| `deploy` | `Railwatch.config.deploy` — auto-detected from the deploy environment, `REVISION`, or Git checkout as documented in [`configuration.md`](configuration.md#core). |
| `server` | `Railwatch.config.server` — hostname by default. |
| `_group` | 128-bit grouping hash (MD5 of type-specific parts, `Record.group_hash`) the platform uses to bucket occurrences into one issue/row. |

Each gzip NDJSON batch also has a small HTTP-header envelope. Drop accounting
rides as `X-Railwatch-Dropped` and `X-Railwatch-Dropped-Bytes` when non-zero.
`X-Railwatch-Backpressure-Factor` is present when adaptive backpressure has
reduced sampling. For example, `4.0` means each configured execution sample
rate was divided by four when the batch was sent. The reporter doubles the
factor on each pressured tick up to 8, then halves it toward 1 as pressure
clears. This makes buffer loss visible alongside the sampling response that
was active at delivery time.

Records created inside an execution also merge in the execution's
envelope. That is everything except the five parent types, plus
`user`/`process`/`visit`, which stand alone. The envelope comes from
`Execution#envelope` in `lib/railwatch/execution.rb`:

| Field | Meaning |
|---|---|
| `trace_id` | Shared by a request and every job it enqueues (`JobTracing`), so a chain of async work traces back to the request that started it. |
| `execution_source` | `"request"`, `"job"`, `"scheduled_task"`, `"command"`, or `"channel_action"`. |
| `execution_id` | UUID of the parent execution this child belongs to. |
| `parent_id` | UUID of the execution that enqueued this one (e.g. the request that enqueued a job), or nil. |
| `execution_preview` | Human label for the parent, e.g. `"GET /posts"` or `"PostsController#index"`. |
| `execution_stage` | Lifecycle stage active when the record was created (`middleware_before`, `action`, `render`, `middleware_after`, ...). |
| `user` | Resolved user id (`Subscribers::Users`), or nil. On a job, the id propagated from whatever enqueued it (see `job_attempt` below). |
| `tenant` | `Railwatch.context(tenant: ...)` / `Context.current_tenant`, or nil. On a job, the tenant propagated from whatever enqueued it. |

## Parent records

`request`, `job_attempt`, `scheduled_task`, `command`, and
`channel_action` are the five parent types, listed in
`Railwatch::PARENT_TYPES`. Each opens an
`Execution`. In addition to its own fields below, each always carries
these fields, from `Railwatch.build_parent` in `lib/railwatch.rb`:

| Field | Meaning |
|---|---|
| `duration` | Wall time in microseconds, execution start to finish. |
| `stages` | Hash of stage name → microseconds spent in it (e.g. `{"middleware_before" => 120, "action" => 4300, "render" => 900}`). |
| `counters` | Hash of child-record counts for this execution — `queries`, `cached_queries`, `exceptions`, `logs`, `cache_events`, `jobs_enqueued`, `mail`, `broadcasts`, `notifications`, `outgoing_requests`, `storage_ops`, `view_renders`, `transactions`, `hydrated_models`, `lazy_loads`, `deprecations`, `spans` (`Execution::COUNTERS`). Counted even when the execution is sampled out, so aggregate rates don't depend on the sample rate. |
| `peak_memory` | RSS in bytes, sampled at most once per second process-wide (`Execution.sampled_memory`) — cheap enough to read but not per-execution-accurate to the microsecond. |
| `allocations` | Objects allocated during the execution (`GC.stat(:total_allocated_objects)` delta). |
| `gc_time` | GC time in the execution's window, when the Ruby build exposes `GC.stat(:time)`. |
| `exception_preview` | First unhandled exception's `"Class: message"`, truncated to 255 chars, or nil. |
| `context` | Serialized `Railwatch.context(...)` key/values active for this execution, parameter-filtered like request params. `"_railwatch_truncated": true` when it did not fit in 64KB. |

A sampled-out execution still ships its parent record if it raised an
unhandled exception. See `Railwatch.finish_execution`. Sampling controls
whether child records ship, not whether an error is visible.

### `request`

Built by the outermost Rack middleware in
`lib/railwatch/middleware/request.rb`. That middleware also owns the
`middleware_before`/`action`/`render`/`middleware_after` stage
boundaries. The `action`/`render` boundaries come from
`start_processing.action_controller` and `render_template.action_view` in
`lib/railwatch/subscribers/requests.rb`.

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
| `inertia` | Present only on an Inertia request (`X-Inertia` header or an Inertia render happened): `{component, version, partial_component, partial_only, partial_except, props_bytes, ssr_ms}`. `ssr_ms` is only set when `inertia_rails` SSR actually rendered this request (`lib/railwatch/patches/inertia.rb`). |
| `headers` | Request headers as a hash, header names Title-Cased; values matching a redacted pattern replaced with `Redactor::FILTERED` (`lib/railwatch/redactor.rb`). |
| `payload` | Filtered request params — only captured when `config.capture_request_payload` is on **and** the request raised an exception (never for successful requests). |
| `user_agent` | Truncated to 256 chars. |
| `files` | Array of `{name, size, content_type, error}` for each uploaded file in a multipart request (metadata only, never contents). A non-multipart request body is never parsed to fill this in. |
| `profiled` | `true` when a `profile` record shipped for this request; absent otherwise. |

### `job_attempt`

One per Active Job `perform`, from the `perform.active_job` event in
`lib/railwatch/subscribers/jobs.rb`. Covers jobs Solid Queue's own
recurring scheduler didn't originate. See `scheduled_task` below for the
ones it did.

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

`user` and `tenant` on a job attempt come from the execution that
enqueued the job, not from the worker process. The worker usually has no
signed-in user to resolve. The same applies to every child record under
the attempt. `JobTracing#serialize` puts the enqueuing execution's
resolved user id and tenant into the Active Job payload as
`railwatch_user`/`railwatch_tenant`, alongside
`railwatch_trace_id`/`railwatch_parent_id`. `perform_start` restores them
onto the job's execution before its first record is built. Details worth
knowing:

- **Identifiers only.** Two strings: the same tenant-prefixed id the
  `user` record carries, and the tenant name. No user or tenant model is
  serialized, hydrated, or looked up, on either side. When the enqueuing
  request had not bound its tenant yet, the raw id travels. The worker
  then qualifies it with the propagated tenant on restore.
- **Jobs enqueuing jobs.** A job serializes the values it was given, so a
  chain of jobs keeps the identity of the request that started it.
- **Retries and scheduled jobs.** A retry re-enqueues the same job object,
  and Active Job re-serializes it, so every attempt keeps the original
  identity. `perform_later(wait:)`/`set(wait_until:)` serialize at enqueue
  time like any other job. A job scheduled for next week is attributed to
  whoever scheduled it. Solid Queue's recurring scheduler enqueues nothing
  on anyone's behalf, so a `scheduled_task` has no propagated user and
  falls back to local resolution, normally nil.
- **Nothing to propagate.** The keys are omitted from the payload when
  there is no user or tenant. A payload without them deserializes to nil
  and falls back to `Users.resolve_from_current`, exactly as before. That
  covers a job enqueued by an older version of the gem, still sitting in
  a queue through a deploy. Inline `perform_now` never serializes, so it
  resolves locally too.
- **A propagated user does not emit a `user` record.** The worker skips
  local resolution, and it is resolution that emits the name/email record.
  The enqueuing process already emitted it for that id.
- **Cardinality.** The user id is one more high-cardinality dimension on
  every job record. Apps that do not want a user attached to jobs at all
  can return nil from `config.user` for the cases they care about. The
  propagation only ever carries what that resolver already produced.

Also has a special case with no `Execution`: **Solid Queue pruned jobs**,
from `fail_many_claimed.solid_queue`. These never reach
`perform.active_job` because their worker was killed or reaped. Each gets
its own throwaway execution and reports `job_attempt` with `job_id: nil`,
`name: "(pruned)"`, `status: "failed"`, `duration: 0`, and
`exception_preview` set to the pruning error, truncated to 255 chars.

### `scheduled_task`

Same `perform.active_job` subscriber as `job_attempt`, but for a job
Solid Queue's `RecurringExecution` table shows was triggered by
`config/recurring.yml` rather than an ad hoc enqueue. See
`recurring_task_key` in `lib/railwatch/subscribers/jobs.rb`. Carries
every `job_attempt` field above, plus:

| Field | Meaning |
|---|---|
| `task_key` | The `config/recurring.yml` key. |
| `group` | Hash of the task key (not the class name). |
| `schedule` | The task's configured schedule string (e.g. `"every day at 3am"`), looked up from `SolidQueue::RecurringTask`, refreshed at most once per 60s. |
| `drift` | Microseconds between the task's scheduled `run_at` and when this attempt actually started. |

### `command`

One per top-level `bin/rails runner` invocation or Rake task invocation.
Prerequisites nest inside the same command instead of opening their own.
See `lib/railwatch/patches/rake_task.rb`'s comment on `Rake::Task#invoke`
vs `#execute`. `db:migrate` and other tasks in
`Configuration::DEFAULT_VENDOR_COMMANDS` are skipped unless
`config.capture_default_vendor_commands` is on.

| Field | Meaning |
|---|---|
| `group` | Hash of the task/command name. |
| `class` | `"Rake::Task"` or `"Rails::Command::RunnerCommand"`. |
| `name` | Task name, or `"runner"`. |
| `command` | Full invocation, e.g. `"rake db:seed[foo]"` or `"rails runner SomeScript.run"`. |
| `exit_code` | 0 on success, `SystemExit`'s status, or 1 on an unhandled exception, clamped to 0-255. |
| `interactive` | `true` on a `bin/rails runner` an engineer typed or piped (`-`, inline code, or a `.rb` file under `config.interactive_runner_paths`); absent otherwise. Such a run ships this record — with its `exit_code` and `exception_preview` — but its exception is not reported. A deployed script (`rails runner script/nightly.rb`), a rake task, and a job are never interactive. See [Console and runner sessions](replacing-sentry.md#12-console-and-runner-sessions). |

### `channel_action`

One parent per Action Cable channel action. Railwatch opens it before
`perform_action.action_cable` invokes application code and closes it
after the action returns or raises. The SQL, logs, broadcasts, transmits,
and exceptions inside therefore share one trace. An Action Cable action
has no HTTP request and no Rack middleware around it, so without this
they had no parent at all.

| Field | Meaning |
|---|---|
| `group` | Hash of channel class + action. |
| `channel` | Channel class name, e.g. `ChatChannel`. |
| `action` | Invoked channel action name. |
| `status` | `"processed"` or `"failed"`. |
| `failed` | Whether the action raised. |

Sampling uses `sample[:channels]` / `RAILWATCH_CHANNEL_SAMPLE_RATE`. An
unhandled channel exception is still eligible for exception sampling and ships
with this parent even when the channel sample rate is zero.

## Child records

### `query`

Every non-cached `sql.active_record` notification except `SCHEMA`,
`TRANSACTION`, and `EXPLAIN` statements. See
`lib/railwatch/subscribers/queries.rb`. The hottest record type in the
gem. It is built as one hash literal rather than going through
`Railwatch.record`.

| Field | Meaning |
|---|---|
| `_group` | Hash of the normalized SQL shape + connection (`SqlNormalizer`); adapter is its own field. |
| `sql` | Normalized SQL shape, truncated to 16,384 chars — literals and comments removed. Set `capture_sql_values` / `RAILWATCH_CAPTURE_SQL_VALUES` to send the raw adapter SQL instead. Active Record's separate structured binds are never sent either way. |
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
| `explain` | The adapter's own query plan (Postgres `EXPLAIN`, SQLite `EXPLAIN QUERY PLAN`, ...), truncated to 4000 chars, or nil. Only when `config.capture_query_explain` is on (its own privacy decision — the plan is produced from the raw statement and can echo literal predicates even though `sql` above is normalized), the statement is a `SELECT`, and it took at least `config.explain_threshold_ms`; then at most once per query shape per process per 10 minutes. The EXPLAIN runs on the same connection the query used, with Railwatch paused, so it never becomes a `query` record of its own. |

A cached query, where `payload[:cached]` is set, only increments the
execution's `cached_queries` counter. It never becomes a `query` record.

### `n_plus_one`

Fired once per query group when its count within the current execution
crosses `config.n_plus_one_threshold`. See
`lib/railwatch/subscribers/queries.rb`. Not on every repeat, just the
crossing.

| Field | Meaning |
|---|---|
| `group` | Same group hash as the triggering `query` record. |
| `sql` | Normalized (parameter-stripped) SQL shape, truncated to 2048 chars. |
| `count` | How many times this group had run in the execution when the threshold was crossed. |
| `source` | App-code call site. |

### `transaction`

One per `transaction.active_record`. See
`lib/railwatch/subscribers/queries.rb`.

| Field | Meaning |
|---|---|
| `group` | Hash of connection name + outcome. |
| `duration` | Microseconds. |
| `outcome` | `"commit"`, `"rollback"`, etc. (`payload[:outcome]`). |
| `connection` | Database config name. |
| `statement_count` | Number of `sql.active_record` statements counted against this transaction object while it was open. |

### `exception`

Every error that reaches `Rails.error`, handled or not. Also anything
the request middleware or command patches catch directly, and anything a
controller swallows with `rescue_from`. See
`lib/railwatch/subscribers/exceptions.rb`. Standalone-capable: reports
even with no execution open, such as a console or boot. Deduplicated per
error object, execution, and handled/unhandled disposition. Rails.error
plus outer middleware therefore report a re-raised error only once, while
the same object reused in another execution is not suppressed. A capture
discarded by sampling or `Railwatch.pause` does not mark the object as
seen. Unhandled exceptions bypass the execution buffer.
`Railwatch.record_now` enqueues the record and wakes the in-memory
reporter immediately, without network I/O on the application thread. This
improves the chance of delivery before a normal exit but is not a durable
crash spool. A hard kill, OOM, or exit after the shutdown deadline can
lose the record.

| Field | Meaning |
|---|---|
| `group` | Hash of this record's `fingerprint` parts. |
| `fingerprint` | The parts that were hashed, up to 10 strings of 200 chars each — by default class + top in-app frame's file/line + normalized message. Always present, so the platform can show *why* an occurrence grouped where it did. |
| `fingerprint_source` | Where the fingerprint came from: `"default"`, `"report"` (`Railwatch.report(error, fingerprint: [...])`), `"error"` (the exception's own `#railwatch_fingerprint`), or `"resolver"` (a `Railwatch.fingerprint { }` block). |
| `class` | Exception class name. |
| `message` | Truncated to 4096 chars. |
| `handled` | Whether the error was rescued (`Rails.error.handle`) vs. unhandled (`Rails.error.report`/escaped). |
| `severity` | `:error`/`:warning`/etc., as a string. |
| `source` | Free-text source tag the raiser passed, e.g. `"application.active_job"`, `"application.action_cable"` (a channel action that raised), `"railwatch.middleware"`, `"action_controller.rescue_from"`, or `"browser"` for a JavaScript error (see below). |
| `file` / `line` | Top in-app backtrace frame. |
| `frames` | Full backtrace (`Backtrace.frames`), each frame optionally with source snippet lines if `config.capture_exception_source` is on. Read from `backtrace_locations`, or parsed from the String backtrace when that is nil (an exception whose backtrace was assigned with `set_backtrace` or delegated to a wrapped error, as `ActiveRecord::StatementInvalid` and `Faraday::Error` do). |
| `cause` | `{class, message}` of `error.cause`, truncated, or nil. |
| `context` | Serialized `Railwatch.context(...)` active when the error was captured, merged with capture-specific context. An Active Job retry captured by `capture_job_retry_errors` adds `attempt` and `wait` (seconds). |
| `code` | `Errno` constant, or `error.errno`/`error.code` if the error exposes one. |
| `sql_state` | Postgres SQLSTATE, for `ActiveRecord::StatementInvalid` wrapping a driver error that exposes one (not populated for SQLite). |
| `ruby_version` / `rails_version` | Process versions. |

A handled exception on a sampled-out execution is dropped entirely,
matching everything else. An *unhandled* one still ships, governed by
its own `exceptions` sample rate rolled once per execution. See
`exception_sampled?`.

The default fingerprint normalizes the message before hashing it, so one
issue doesn't shatter into thousands. URLs, email addresses, UUIDs, ISO
timestamps, IPv4 addresses, quoted strings, hex runs of six characters or
more, and plain integers all become `?`. Whitespace collapses, and the
result is cut at 200 chars. For classes whose message is mostly the data
that varied, only the message *prefix* is kept. The prefix runs up to the
first `:` for `ActiveRecord::RecordNotFound`, `ActiveRecord::RecordInvalid`,
`KeyError`, `ArgumentError`, and `TypeError`, and up to the first `for `
for `NoMethodError` and `NameError`. So `key not found: :order_id` and
`key not found: :user_id` are one issue rather than two. Override any of
it with `Railwatch.fingerprint`, `#railwatch_fingerprint`, or
`Railwatch.report(error, fingerprint: [...])`. See
[`docs/configuration.md`](configuration.md).

An error whose class, or any named ancestor of it, appears in
`config.ignored_exceptions` is never captured at all, handled or not.
An error a controller rescues with `rescue_from` is captured as
`handled: true`, `severity: "warning"`, `source:
"action_controller.rescue_from"`. That comes from Rails'
`rescue_from_callback.action_controller` notification. Set
`config.capture_rescued_exceptions = false` to turn it off. Active Job's
equivalents, `retry_on` exhausted and `discard_on`, are already covered
by the `retry_stopped`/`discard` subscriptions in
`lib/railwatch/subscribers/jobs.rb`. A retry that has not exhausted its
attempts is logged but is not an exception by default. Set
`config.capture_job_retry_errors = true` to capture it as handled with
severity `warning` and source `application.active_job.enqueue_retry`. This
is off by default because retries are usually expected and can flood the
issues list. See [`docs/configuration.md`](configuration.md) for both
settings.

#### Browser errors (`source: "browser"`)

Every JavaScript error the browser client catches arrives on the same
beacon as visits, `POST /railwatch/beacon`, 50 errors per beacon at most.
That covers `window.onerror`, unhandled promise rejections, Inertia's
failed-request events, and anything the app reports itself with
`reportError`. The Inertia events are `exception` and `invalid` on
Inertia 2, `networkError` and `httpException` on 3. A dropped connection
is reported only while the user is waiting on a visit that shows the
progress bar or loads deferred props, not for a background poll,
`router.reload`, or prefetch. Each error is recorded as an ordinary
`exception`: `source: "browser"`, `handled: false`, `severity: "error"`,
`class` set to the JavaScript error's `name`, `message` truncated to 1024
chars. It carries the same envelope every other record does, including
`deploy`, so a browser issue regresses with a release exactly like a Ruby
one.

The browser's stack, 8192 chars at most, is parsed into the same frame
shape a Ruby backtrace produces. V8's `at fn (url:line:col)` and
SpiderMonkey/JavaScriptCore's `fn@url:line:col` are both understood. A
line with no location on it is dropped:

| Frame key | Meaning |
|---|---|
| `file` | Path relative to the app's own origin (`assets/index-Bq1x9K.js`, `app/frontend/pages/orders/index.tsx`), or the whole URL for a script served from anywhere else. Any query string is cut. |
| `line` | Line number. Columns are parsed but not stored. |
| `function` | The function name the engine gave, or `"(anonymous)"`. |
| `in_app` | True when the script came from the app's own origin and is not under `node_modules/` or `vendor/`. |

No source snippets: the file is on the client, not on the server. Frames
are fingerprinted exactly like Ruby ones: class, top in-app frame, and
the normalized message. So browser errors group, split, merge, resolve,
and regress through the same Issue machinery.

`context` carries a `browser` key with the page `url`, the Inertia
`component`, the `visit` the error happened in if any, the tab's
`session` id, the `user_agent`, and up to 20 `breadcrumbs`. Each
breadcrumb is `{at, kind, text}`, with `kind` being `console`, `click`,
or `navigate`. The breadcrumbs are the trail the client recorded before
the crash. Anything the app passed as `reportError(error, context)` is
merged in alongside it, flattened to strings, 20 keys at most.

### `cache_event`

Every `cache_*.active_support` notification except the inner read inside
a `fetch`. See `lib/railwatch/subscribers/cache.rb`. Vendor cache key
prefixes are skipped unless `config.capture_default_vendor_cache_keys` is
on. By default those are rack-attack, flipper, and solid_cable. Keys
matching `config.ignored_cache_key_prefixes` are always skipped.

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

`deliver.action_mailer`. See `lib/railwatch/subscribers/mail.rb`.

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

A mailer's own template render is a separate `view_render` record via
`process.action_mailer`, `kind: "mailer"`. See below.

### `broadcast`

Action Cable broadcast/transmit/perform. This also covers Turbo Streams
and `inertia_cable`, since both go through `broadcast.action_cable`. See
`lib/railwatch/subscribers/broadcasts.rb`. Three sub-shapes share the
type:

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

Noticed gem deliveries only. See
`lib/railwatch/subscribers/notifications.rb`. Tagged by hooking the same
`perform.active_job` event the `job_attempt` subscriber uses, filtered to
jobs whose class starts with `Noticed::`. No-ops entirely if the
`noticed` gem isn't loaded.

| Field | Meaning |
|---|---|
| `group` | Hash of the Noticed delivery job's class name. |
| `notifier` | The `notification_class` from the job's first argument, if present. |
| `channel` | Delivery class with `Delivery` stripped and lowercased, e.g. `"email"`, `"slack"`. |
| `delivery_method` | Delivery job class, demodulized (e.g. `"EmailDelivery"`). |
| `duration` | Microseconds. |
| `failed` | Whether the delivery job raised. |

### `outgoing_request`

Any `Net::HTTP#request` call, via `lib/railwatch/patches/net_http.rb`.
That covers Faraday's default adapter, HTTParty, RestClient, and most of
the HTTP ecosystem. Also Faraday connections that explicitly add
`Railwatch::Faraday` middleware from `lib/railwatch/faraday.rb`, for apps
using a non-default Faraday adapter. Requests to Railwatch's own ingest
URL are always skipped so shipping telemetry never generates telemetry
about itself. A Faraday connection using the default Net::HTTP adapter
defers to the Net::HTTP patch via a thread-local reentry flag, so it's
never double-recorded.

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

### `llm_call`

Every RubyLLM model call and tool invocation, from
`lib/railwatch/subscribers/llm.rb`. RubyLLM publishes its own
`ActiveSupport::Notifications` events, so nothing is patched and RubyLLM is
not a dependency — an app without it never emits these. Requires RubyLLM
1.16 or later, which is where its instrumentation landed.

The model call also appears as an `outgoing_request`, since it is an HTTP
call like any other. The two are different grains on purpose: the
`outgoing_request` is the HTTP truth, the `llm_call` is what it cost. That
difference is useful: RubyLLM retries through Faraday, so one `llm_call`
with several `outgoing_request` rows against it in the same execution is a
call that was retried. Over a window, `outgoing_requests - llm_calls` to the
same provider host is the number of *extra attempts*, not a rate -- the
share of calls that were retried needs counting the calls with more than one
request against them, which the execution id supports.

**Token counts and cost differ by RubyLLM version.** 1.16 reports token
counts and no cost at all. 2.0 reports both, from its usage ledger, and
adds the `workflow_*` fields. `cost_nanos` is null rather than zero
whenever RubyLLM reported no cost or the model registry could not price
it — an unpriced call is not a free one.

**Tool calls run on their own threads are not recorded.** RubyLLM's opt-in
`tool_concurrency: :threads` runs each tool in a fresh thread.
`Railwatch::Current` is backed by `ActiveSupport::IsolatedExecutionState`,
which a new thread does not inherit, so the `tool_call.ruby_llm` event
fires with no execution to attach to and the record is dropped rather
than misattributed. This affects every Railwatch subscriber in an
app-spawned thread, not just this one. `:fibers` depends on Rails'
isolation level: under the default, `:thread`, fibers share their
thread's state and the tool calls are recorded; with
`config.active_support.isolation_level = :fiber` they are dropped the same
way. Tool concurrency is off by default; with it off, tool calls are
recorded normally. The model calls themselves are unaffected either way,
so cost is always complete.

| Field | Meaning |
|---|---|
| `group` | Hash of provider + model + operation, or of `"tool"` + tool name. |
| `operation` | `"chat"`, `"compaction"`, `"embedding"`, `"image"`, `"speech"`, `"transcription"`, `"moderation"`, `"rerank"`, `"ocr"`, or `"tool"`. |
| `provider` | Provider slug, e.g. `"anthropic"`. |
| `model` | Model the call was made with. Empty for a provider that selects its own (moderation). |
| `response_model` | Model the provider says answered, which can differ from the one asked for. |
| `tool_name` | Tool name, for `operation: "tool"`. |
| `duration` | Microseconds. |
| `status` | `"ok"`, or `"failed"` if the call raised. |
| `error` | `"Class: message"`, truncated to 255 chars, if the call raised. |
| `streaming` | Whether the call was streamed. |
| `message_count` | Conversation length at the time of the call. |
| `tool_count` | Number of tools the model was offered. |
| `input_tokens` | Standard (non-cached) input tokens. |
| `output_tokens` | Billable output tokens. |
| `cache_read_tokens` | Tokens served from the provider's prompt cache. |
| `cache_write_tokens` | Tokens written to the provider's prompt cache. |
| `thinking_tokens` | Reasoning tokens, where the provider reports them separately. |
| `cost_nanos` | Cost in billionths of a US dollar. Null when unpriced — see above. Nanodollars because a cheap call is well under a microdollar and floats do not sum to an invoice. |
| `workflow_id` | `RubyLLM.workflow` identifier (2.0+). Null outside a workflow. |
| `workflow_name` | Workflow name (2.0+). |
| `workflow_step_id` | Step identifier within the workflow (2.0+). |
| `workflow_step_name` | Step name (2.0+). |
| `workflow_step_parent_id` | Enclosing step, for nested steps — what reconstructs the tree (2.0+). |
| `finish_reason` | Why the model stopped: `stop`, `max_tokens`, `tool_calls`, `content_filter`, or whatever the provider spelled it. `max_tokens` means the answer was cut off -- without this a truncated extraction reads exactly like a complete one. |
| `provider_request_id` | The provider's own id for the request, read from the response headers (`request-id`, `x-request-id`, `x-amzn-requestid`). The only key that joins this record to the provider's side of it, and what a support ticket asks for. |
| `tools` | Comma-separated names of the tools the model could reach, first 50. `tool_count` says how many; retracing needs which. |
| `cost_reported` | Whether the provider priced the call itself, or the amount is an estimate from the model registry. Null on gems or operations that report no cost. |
| `attachments` | How many files the last user turn carried. Absent when it carried none. Only the last turn is measured: earlier turns were counted by the calls that sent them. |
| `attachment_types` | What they were, by category and count, e.g. `imagex2,pdf`. Categories are RubyLLM's: image, pdf, audio, video, text, document, unknown. On a document-reading call the attachments are most of the input tokens, so without this an expensive scan is indistinguishable from an expensive prompt. |
| `attachment_names` | Filenames, only when `config.capture_llm_content` is on. A filename like `ACME_invoice_88231.pdf` is business data, not metadata, so it follows the same switch as prompts. |
| `params` | JSON of the settings that produced the answer, so a surprising one can be reproduced: `temperature`, `max_output_tokens`, `tool_choice`, `tool_call_limit`, `thinking`, `caching`, `citations`, whether a `schema` was used, plus the per-operation ones (`dimensions`, `task_type`, `size`, `count`, `voice`, `format`, `language`, `pages`, `document_count`, `top_n`), `server_tools` and the provider's `server_tool_use` counters. `provider_options` is included, filtered twice: through the app's own parameter filter, and again against the credential-name matcher that catches `X-Api-Key` on a header -- an `api_key` passed per call sails straight through a password-shaped filter. For `operation: "tool"` this holds the tool result's class instead. |
| `tool_call_id` | The provider's id for a tool invocation, for joining a tool call to the assistant turn that asked for it. |
| `prompt` | Last user turn, only when `config.capture_llm_content` is on (off by default). Capped at 4 KiB of bytes. |
| `completion` | The reply, same condition and cap. For `operation: "tool"` these two hold the tool's arguments and result instead. |

### `storage_op`

Every Active Storage service operation. See
`lib/railwatch/subscribers/storage.rb`. The operations are upload,
download, streaming download, delete, delete_prefixed, exist, url,
update_metadata, analyze, transform, preview.

| Field | Meaning |
|---|---|
| `group` | Hash of service name + op. |
| `service` | Active Storage service name. |
| `op` | Operation, `service_` prefix stripped (e.g. `"upload"`, `"analyze"`). |
| `key` | Blob key, truncated to 255 chars. |
| `duration` | Microseconds. |
| `exist` | For `exist` ops, whether the blob existed. |

### `view_render`

Template, partial, layout, and collection renders, from
`lib/railwatch/subscribers/views.rb`. Plus mailer template renders, from
`process.action_mailer` in `lib/railwatch/subscribers/mail.rb`, with
`kind: "mailer"`. Only the first `config.max_view_renders_per_execution`
per execution are stored as records. All are still counted toward the
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

Custom timing around any block of app code:
`Railwatch.span(name, **attributes) { ... }`, in `lib/railwatch.rb`.
Returns the block's value untouched. It is a no-op wrapper when Railwatch
is disabled, nothing is executing, or the execution isn't recording. It
still yields in that case. Every span also increments the parent's
`spans` counter.

```ruby
Railwatch.span("pdf.render", template: "invoice", pages: 12) { renderer.call }
```

| Field | Meaning |
|---|---|
| `group` | Hash of the span name. |
| `name` | Span name, truncated to 255 chars. |
| `duration` | Microseconds. |
| `attributes` | Up to 25 keys; values stringified (`inspect` for anything that isn't already a String), truncated to 200 chars, and run through the same parameter filter as request params and exception locals — so a `password:` attribute ships as `[FILTERED]`. nil when the call passed no attributes. |
| `status` | `"ok"`, or `"failed"` if the block raised — the exception is recorded and then re-raised untouched. |

### `attachment`

An arbitrary blob filed against an execution and, optionally, an
exception: `Railwatch.attach(name, data, content_type:, exception:)`, in
`lib/railwatch/attachments.rb`. For example the payload that failed to
parse, a rendered PDF, or the webhook body a customer swears they sent.
Sentry's `Sentry.add_attachment` equivalent.

```ruby
Railwatch.attach("payload.json", request.raw_post)
Railwatch.attach("invoice.pdf", Rails.root.join("tmp/invoice.pdf"))
Railwatch.attach("payload.json", body, exception: error)
Railwatch.report(error, attachments: { "payload.json" => body })
```

`data` may be a String, a `Pathname`, or any IO. A String is the bytes
themselves; a `Pathname` is read as a file. This is one of the standalone
types, listed in `Railwatch::STANDALONE_TYPES`. Inside a recording
execution it ships as a child of it. With nothing executing, such as a
boot hook, a console, or a rescue outside any request, it ships on its
own. Returns nil and records nothing when Railwatch is disabled or the
payload is empty.

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

Two independent sources feed this type. See
`lib/railwatch/subscribers/logs.rb`. The first is `Rails.logger` lines,
captured by broadcasting to a `Logger` subclass that intercepts every
`add` call. The second is Rails 8.1's structured `Rails.event` framework
events. Lines matching Rails' own per-request/job noise are dropped:
`"Started GET"`, `"Processing by"`, `"Rendered"`, etc. Those are already
covered by the `request`/`job_attempt` records. Lines below
`config.log_level` and Railwatch's own `[railwatch]`-prefixed debug
output are dropped too. Framework structured events such as
`action_controller.*` and `active_record.*` are dropped unless
`config.capture_framework_events` is on, for the same reason.

| Field | Meaning |
|---|---|
| `level` | `"debug"`/`"info"`/`"warn"`/`"error"`/`"fatal"`/`"unknown"` for a logger line, `"event"` for a structured event. |
| `message` | Logger line text (ANSI color codes stripped), or the event name, truncated to 8192 chars. Message text is otherwise sent as written; parameter redaction does not parse secrets embedded in a line. |
| `tags` | Active `Rails.logger.tagged` tags, for a logger line; the event's own tags, for a structured event. |
| `context` | Serialized `Railwatch.context(...)`, for a logger line; the event payload as JSON (truncated to 8192 chars), for a structured event. |
| `source` | File:line the structured event fired from, when available (structured events only). |

### `enqueued_job`

`enqueue`/`enqueue_at`/`enqueue_all.active_job`, in
`lib/railwatch/subscribers/jobs.rb`. One record per job enqueued. Distinct
from `job_attempt`/`scheduled_task`, which record the later `perform`.

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

Standalone. Emitted once per distinct user id per process-hour, not per
request, so the platform can show names/emails without every other
record carrying them. See `lib/railwatch/subscribers/users.rb`. Resolved
via `config.user` block if set, else `Current.user` from
authentication-zero or the Rails 8 auth generator, else Warden from
Devise. The process-hour cache entry is written only once the execution
carrying the entity has been handed to the reporter. So a sighting that
was sampled out or paused does not suppress the next sighting that would
ship. Forked workers start with an empty cache.

| Field | Meaning |
|---|---|
| `id` | Resolved user id, tenant-prefixed (`"tenant:id"`) when a tenant is bound — including when it binds *after* the user was resolved. |
| `name` | Truncated to 255 chars. |
| `email` | Truncated to 255 chars. |
| `tenant` | Current tenant context, if any. |

### `deprecation`

`deprecation.rails`. See `lib/railwatch/subscribers/deprecations.rb`. Rails
only emits that notification when `config.active_support.deprecation`
includes `:notify`; see [Troubleshooting](troubleshooting.md#deprecations-are-counted-but-never-listed).

| Field | Meaning |
|---|---|
| `group` | Hash of gem name + first 120 chars of the message. |
| `message` | Truncated to 2048 chars. |
| `gem_name` | Gem the deprecation came from. |
| `horizon` | Deprecation horizon version string. |
| `source` | First app-code frame in the deprecation's callstack, app-root prefix stripped. |

### `visit`

Standalone. Inertia page-visit timing reported by the browser client,
`app/frontend/lib/railwatch.ts`, generated by `railwatch:install`. POSTed
to `POST /railwatch/beacon` and recorded server-side by
`Railwatch::BeaconController` in
`app/controllers/railwatch/beacon_controller.rb`. Batched client-side:
flushed every 5s, on `pagehide`, or once 20 visits queue up. Capped at 50
visits per beacon request, and at `config.beacon_rate_limit` requests per
client IP per minute. The default is 120; `0` turns the limit off. No-ops
entirely if `config.beacon_enabled` is off.

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
never routed it. It has `method` `"GET"`, `status` `"success"`, and
`component` read from the Inertia root's `#app[data-page]` JSON. Its
`duration` is taken from navigation timing: `loadEventEnd` or
`responseEnd`, minus `startTime`. It is the only visit that carries the
four Core Web Vitals. It is held back until the page is first hidden, on
`visibilitychange`/`pagehide`, so those numbers are final when it ships.
Every vital is nil on a browser that doesn't support the
`PerformanceObserver` entry type behind it.

### `session`

Standalone. One session of the monitored app, for release health. The
`deploy` on the envelope *is* the release. The platform counts sessions
per deploy and reports crash-free rates from them. Two sources produce
the same record:

- **Browser**, `source: "browser"`. The client,
  `app/frontend/lib/railwatch.ts`, mints a 16-hex id per tab in
  `sessionStorage` under the key `railwatch.session`, so it dies with the
  tab. It mirrors the id into a `railwatch_session` cookie and sends it
  with every beacon flush. `Railwatch::BeaconController` writes at most
  one `session` record per flush. The first, with no `duration_ms` yet,
  opens the session. Later ones beat it along, and the
  `pagehide`/`visibilitychange` flush closes it with `ended`.
- **Server**, `source: "server"`. `lib/railwatch/sessions.rb` aggregates,
  per process, every request that resolves a user or carries that cookie
  or an `X-Railwatch-Session` header. A background thread ships one
  record per session every `config.session_flush_interval`, default 60s.
  A session idle for `config.session_timeout`, default 30 minutes, ships
  with `ended` and is dropped. At most 10,000 keys are tracked per
  process. Past that the oldest is dropped and counted in
  `Railwatch::Sessions.dropped`.

Both are off when `config.track_sessions` is false. Both key on the same
id when the browser cookie is present, so the platform dedupes the two
halves of one session rather than counting it twice.

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

Standalone. One per process boot, from
`lib/railwatch/subscribers/process_info.rb`. Fired unconditionally during
subscriber installation, not gated on sampling. Gives the platform a
server/deploy inventory for free.

| Field | Meaning |
|---|---|
| `pid` | Process id. |
| `role` | `"web"` (Puma present), `"worker"` (Solid Queue supervisor, `$PROGRAM_NAME` includes `"jobs"`), `"console"`, `"command"` (`$PROGRAM_NAME` ends in `rake`), or `"process"`. |
| `ruby_version` / `rails_version` / `railwatch_version` | Versions. |
| `app` | Top-level module name of the Rails app. |
| `environment` | `config.environment_name` (defaults to `Rails.env`). |
| `boot_seconds` | Monotonic time from `Railwatch::BOOTED_AT` (the gem's load time, as early in boot as it can observe) to `config.after_initialize`, when the record is written -- so it covers the app's own initializers. |
| `database_adapter` | Primary DB adapter name. |
| `queue_adapter` | Active Job queue adapter name. |
| `cache_store` | `Rails.cache` class name. |

### `health`

Standalone. One every `config.health_interval` seconds, default 15, from
a single background thread per process. See `lib/railwatch/health.rb`.
The thread is started by the engine's `railwatch.health` initializer
only when Railwatch is enabled, the process `role` is `"web"` or
`"worker"`, and the Rails env isn't `test`. This is the gem's only
*sampled gauge*. Everything else is an event; this is a periodic snapshot
of how loaded the process is.

The whole sample runs inside `Railwatch.ignore` and rescues everything.
So a missing constant, an unmigrated queue database, or a checkout
timeout degrades each field to nil instead of raising on a thread nobody
watches. The record still ships with whatever it did manage to read.

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
| `detail` | JSON string: `queues` (ready count per queue name), `workers` (`SolidQueue::Process` rows of kind `Worker`), `requests_count` (Puma's lifetime request count for this process), `running` (threads Puma has spawned), `max_threads_reached` (true when Puma's `pool_capacity` was 0 at sample time, i.e. no spare thread), `recurring_tasks` (Solid Queue recurring task key => schedule, from `SolidQueue::RecurringTask`; left out when there are none or the table could not be read, so the platform can tell a task removed from `config/recurring.yml` apart from one that stopped running). |

Every Puma field is nil when no `Puma::Server` exists in the process, and
every Solid Queue field is nil when `SolidQueue` isn't loaded.

The sampler re-arms itself after `fork`, via Rails'
`ActiveSupport::ForkTracker` callback. So clustered Puma workers and
forked Solid Queue workers each report without any `on_worker_boot`
configuration.

`Railwatch::Health.start!` is idempotent. `stop!` is registered by the
engine's `at_exit`, ahead of the reporter's final flush. It wakes the
thread off its `ConditionVariable` immediately rather than waiting out
the interval.

### `profile`

A sampling profile of one execution. See `lib/railwatch/profiler.rb` and
`Railwatch.start_profile`/`ship_profile` in `lib/railwatch.rb`. Off by
default. See `docs/configuration.md`'s **Profiling** section for how an
execution is picked and which backend gem the app has to install. Exactly
one `profile` per execution, buffered as a child of that execution and
shipped with it. The execution's parent record then carries
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
`stackcollapse` produces. Each line is one unique stack: outermost frame
first, semicolon-separated, then a space and the number of samples that
landed on it.

```
<main> (config.ru:3);WidgetsController#index (app/controllers/widgets_controller.rb:4);ActiveRecord::Relation#each (activerecord-8.1.0/lib/active_record/relation/delegation.rb:89) 37
```

Each frame is `Class#method (path:line)`. The Rails root is stripped from
app paths. An installed gem's path becomes `<gem>/relative/path`; the
version is dropped, since the deploy already records it. Ruby's own
library becomes `ruby/...`. A C function, which has no Ruby file of its
own, reads `<cfunc>:0`. Lines are ordered by sample count descending,
ties broken by the stack text, so the same profile always serialises to
the same bytes.

The text is capped at **4 MiB uncompressed**, by
`Railwatch::Profiler::MAX_COLLAPSED_BYTES`. Past that the least frequent
stacks are dropped, since the shape of a profile lives in its frequent
ones. Rails stacks are deep enough that a busy request can reach the cap.
That is why `samples` is reported separately from the counts in `stacks`.

Both backends are process-global: there is one profiler per process, not
one per thread. So an execution that starts while another is being
profiled simply isn't profiled. Such skips are counted in
`Railwatch::Profiler.skipped`. Vernier samples every thread in the
process, so only the thread that started the profile is folded in.
StackProf samples wherever its `SIGPROF` lands.
