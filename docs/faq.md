# FAQ

## What does it cost per request?

The gem ships with an overhead gate that CI runs on every change
(`bench/overhead.rb`, `bundle exec ruby bench/overhead.rb`). It boots the
dummy app, drives a request that issues 200 queries with Lantern off and
then on, interleaved in short blocks so background load hits both equally,
and fails the build if instrumentation costs more than:

| Budget | Limit |
|---|---|
| Added p50 per request | 1.5 ms of CPU time |
| Added cost per query | 8 µs |
| Added allocations per request | 3,000 |

Measured on an idle core, the gem comes in at roughly **0.4 ms fixed per
request plus about 2 µs per query** — so ~0.85 ms for that deliberately
extreme 200-query request. The limits are higher than the measurement on
purpose: they leave headroom for a loaded CI box without letting a real
regression through.

Two honest caveats. The budget is **CPU time on the request thread**, not
wall time — wall time on a shared runner swings by tens of milliseconds
for reasons that have nothing to do with the gem, which would make the
gate useless. And a request that runs 200 queries is a stress case; a
normal request pays mostly the fixed cost.

A second gate, `bench/no_db_writes.rb`, drives 200 requests and a job with
a `sql.active_record` subscriber watching for any `INSERT`/`UPDATE`/
`DELETE` issued from a frame inside `lib/lantern`, and fails if it finds
one. **Lantern never writes to your application's database.** Records
live in memory and are shipped by a background thread. That is not a
nicety: instrumentation that takes a write lock is what turns a
single-writer SQLite app into a "database is locked" incident.

## Where does the data go, and how long is it kept?

To the platform, over one gzip-NDJSON POST to `{ingest_url}/ingest` per
batch. The platform stores each monitored environment's telemetry in its
own database, prunes raw rows on a retention window, and keeps hourly
rollups for the charts.

Retention is set by the account's plan tier, not by the gem — 7, 30, or
90 days depending on the plan. For a self-hosted install, retention,
backups, and the pruner are yours to run:
[`lantern-cloud/docs/operations.md`](../../lantern-cloud/docs/operations.md).

## What about PII?

Two things are redacted with no configuration:

- **Headers**, by name: `Authorization`, `Cookie`, `Set-Cookie`,
  `Proxy-Authorization`, `X-CSRF-Token`, `X-XSRF-TOKEN`, plus any
  credential-shaped name segment such as `api-key`, `access-key`,
  `private-key`, `auth`, `bearer`, `credential`, `hmac`, `jwt`, `token`,
  `secret`, or `signature` (including vendor headers such as
  `X-Shopify-Hmac-Sha256` and concatenated Rack aliases such as `X-AuthToken`,
  `X-ApiToken`, `X-AccessToken`, `X-ClientToken`, `X-SessionToken`,
  `X-RefreshToken`, `X-SecretKey`, `X-HmacSignature`, and `X-CSRFToken`).
  Values are replaced with `[FILTERED]`. Extend the exact denylist for
  application-specific names with
  `c.redact_headers += [...]`.
- **Parameters**, by name: `password`, `password_confirmation`,
  `authenticity_token`, `_token` — merged with your app's own
  `config.filter_parameters`, so anything already hidden from your logs
  is hidden here too. Extend with `c.redact_params += [...]`.

Four things that could carry PII are **off by default and opt-in one at a
time**. There is no single "send everything" switch:

| Setting | What it adds |
|---|---|
| `capture_request_payload` | Request params — and only for a request that raised, never a successful one. Filtered. |
| `capture_job_arguments` | A job's real arguments, capped at 8 KiB of JSON, hashes filtered. (Argument *shapes* — `arguments_preview` — are always on and carry no values.) |
| `capture_response_body_on_error` | The first 4 KiB of a failing upstream's response body. |
| `capture_exception_locals` | The raising frame's local variables, truncated and filtered. |

Everything else is per record type, in your initializer:
`Lantern.redact_requests`, `redact_queries`, `redact_exceptions`,
`redact_cache_events`, `redact_commands`, `redact_mail`,
`redact_outgoing_requests`, `redact_logs` mutate a record in place;
`Lantern.reject_queries`, `reject_cache_events`, `reject_mail`,
`reject_notifications`, `reject_broadcasts`, `reject_outgoing_requests`,
`reject_enqueued_jobs`, `reject_logs` drop it entirely.
`Lantern.before_ingest` gets the last look at a whole batch.

Who the user is comes from a resolver block you write
(`c.user { |u| ... }`), so the fields on a `user` record are exactly the
ones you chose to put there. Cache keys are truncated at 255 characters
and can be dropped wholesale with `Lantern.reject_cache_keys`; outgoing
request URLs, inbound request URLs, and redirect targets have authority
credentials, entire query strings, and fragments stripped; uploaded files are
recorded as metadata (name, size, content type) and never contents.

## Does SQLite work?

Yes, on both sides, and it's the first-class target.

**In your app:** the gem does no I/O on the request path and never writes
to the app database, so there is no contention with SQLite's single
writer. SQL normalization is per adapter, so SQLite, Postgres, MySQL, and
Trilogy all group correctly.

**On the platform:** telemetry is stored one SQLite database per
monitored environment. That is what makes retention pruning, backup, and
restore per-environment operations rather than one enormous table, and
it's why log search gets FTS5 with snippet highlighting. The platform
runs unchanged on Postgres if that's what's configured.

## One database per environment — what does that mean for me?

Each environment you create (production, staging, ...) has its own
ingest token and its own telemetry store. Nothing crosses between them:
a staging exception storm can't fill production's retention window, and
deleting a staging environment deletes a file. Applications and issues
live in the shared database, so an issue keeps a stable id like
`APP-171` even after the raw rows behind it are pruned.

## Do I need Inertia?

No. The browser client is the only Inertia-specific piece, and it's
optional — it adds `visit` records (page-visit duration, prop bytes,
partial reloads, Core Web Vitals) and the browser half of release health.
Everything else — requests, jobs, queries, exceptions, cache, mail,
logs — is server-side and works on any Rails app, API-only included.

Without the client, sessions still report from the request middleware,
which is the source that can see an unhandled exception anyway.

## Does it work with Sidekiq? Solid Queue?

Both, and anything else with an Active Job adapter. Jobs are
instrumented at the Active Job level (`perform_start.active_job` /
`perform.active_job`), so the adapter is a field on the record rather
than an integration to write. `job_attempt` records carry the adapter's
own id (`provider_job_id`) alongside Active Job's `job_id`.

Two features are Solid Queue-specific, because they read its tables:
`scheduled_task` records (recurring tasks from `config/recurring.yml`,
with `task_key`, `schedule`, and `drift`) and the queue depth and
oldest-job age on `health` records.

## What happens when the platform is unreachable?

Nothing, from your app's point of view. This is the property everything
else is built around: **delivery never raises into application code.**

Concretely. Recording pushes onto a bounded in-memory buffer
(`c.buffer_size`, default 5,000). When it's full the *oldest* record is
dropped and a counter is incremented — the app thread never blocks
waiting for room. The counter rides along on the next successful batch
(`X-Lantern-Dropped`), so loss shows up on the platform instead of being
silent.

A background thread drains the buffer and POSTs. Each POST retries one
raised network error or 5xx immediately. If delivery still fails, the batch
and its drop counter go back into the bounded buffer; **402**, **408**,
**429**, and all **5xx** responses are retained the same way. So is a **2xx
that cannot acknowledge the batch** — a proxy's HTML sign-in page, malformed
JSON, or `accepted`/`rejected` counts that do not cover what was sent — which
would otherwise be a silent drop. The reporter
retries with jittered exponential backoff from one second up to 60 seconds,
so an outage cannot create a busy loop. A retained batch is retried eight
times (about four minutes on that ladder), then dropped and counted so the
buffer's newest records win again; meanwhile newer traffic that overflows
the buffer drops its oldest records, and every loss stays counted.

Connect timeout is 1 second and read/write timeout 3 seconds by default,
both configurable, and they're always on the reporter thread — even an
unhandled exception only enqueues and wakes that thread. A **401** marks the
transport unauthorized and stops further HTTP attempts for that process's
lifetime (fix the token and restart). A 401 or other permanent client
rejection drops that rejected batch and calls `Lantern.on_unrecoverable`
with its status and record count.

Two 2xx shapes are a *successful* drain rather than a failure. An
acknowledgement carrying a `reason`, and an all-zero
`{"accepted":0,"rejected":0}`, are how the platform answers for an
environment it is not currently ingesting for (paused, over quota) — the
batch is released, because retrying it would burn all eight attempts and
drop the records anyway. And `rejected > 0` is routine, not an incident:
the platform rejects individual records it cannot store, records that
already appear on its own ingest batch. Those are visible under
`LANTERN_DEBUG=1` and are deliberately **not** sent to
`Lantern.on_unrecoverable`.

On shutdown, `at_exit` gives the thread `c.shutdown_timeout` (2 seconds) to
attempt retained records immediately and retry within the remaining time.
If the deadline expires, the records stay retained and their count is sent
to `Lantern.on_unrecoverable` (or stderr under `LANTERN_DEBUG=1`). This is an
in-memory buffer, not an on-disk spool: a hard kill, or exiting after that
deadline, cannot carry those records into the next process. Lantern never
uses `Rails.logger` for its own failures, which would turn them into `log`
records about Lantern.

## See also

- [`getting-started.md`](getting-started.md) — install and first request.
- [`configuration.md`](configuration.md) — every option and default.
- [`troubleshooting.md`](troubleshooting.md) — when something is missing.
