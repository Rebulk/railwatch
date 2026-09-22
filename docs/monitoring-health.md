# Monitoring health

Open **Monitoring health** in the environment navigation to see whether
Railwatch is receiving telemetry, keeping up with follow-up work, and managing
its telemetry storage. The overview links to this page when recorded evidence
needs attention.

The page describes the current pipeline, independently of the dashboard's
selected time range. Unknown means the evidence is unavailable or was never
recorded. Not applicable means that capability is disabled or belongs to a
different host mode. Neither is a successful check.

When the embedded schema is pending or incompatible, the authenticated
dashboard displays the schema repair response before reading health tables.
It gives the missing migrations or schema details and the appropriate database
commands. After repair Railwatch rechecks within 30 seconds. An unavailable
individual diagnostic remains unknown rather than being displayed as healthy.

## Recorded evidence

| Check | Source and interpretation |
|---|---|
| Freshness | Newest `IngestBatch.received_at` and `HealthSample.sampled_at`. More than ten minutes old needs attention. No records means unknown. A quiet application can be healthy; freshness alone does not establish the cause. |
| Capture | Accepted records, rejected records, reported client drops, and peak backpressure factor in up to the newest 1,000 batches from the last hour. If more batches exist, the page labels the sample partial and its totals as lower bounds. |
| Backpressure | A factor above 1 reduces capture below configured sampling rates. The factor is evidence of pressure, not a count of all executions skipped. |
| Follow-ups | Oldest pending batch and up to 200 pending batch timestamps. More than five minutes waiting needs attention. A larger queue is shown as “at least 200.” |
| Retention | The oldest row in six indexed tables: queries, exceptions, logs, sessions, process health samples, and ingest batches. Expired rows awaiting the daily prune are visible; a backlog more than a day beyond cutoff needs attention. Sessions retain the partial hour containing the cutoff. |
| Maintenance | Successful completion timestamps and active/expired leases from `MaintenanceTask`. A task is overdue after its interval plus lease allowance, or when a held lease has expired. Failure details are not persisted. |
| Writer | Whether the current process is the writer or expects a shared writer. The active transport and remote writer liveness are not persisted, so they are explicitly unknown. Batch freshness provides evidence of committed work. |
| Export | The configured destination's state, durable queue totals, oldest queued delivery, latest enqueued delivery's state, retry time, and lifetime counters. Shed counts records; acked, rejected, expired and discarded count deliveries. |

Client drops are the loss counts that arrived in committed batches. Loss in a
batch that never reached Railwatch is unknown. Configured sampling also omits
executions deliberately. A zero recorded loss count does not prove that every
execution was captured. Export loss concerns the mirror; it does not mean the
local copy was deleted.

Retention probes do not count all expired rows or inspect every raw table. If
a probe's time index is missing, the page reports unknown and skips the scan.

## SQLite storage and a storage budget

The embedded default remains its own SQLite telemetry database, separate from
the application's data and Railwatch's metadata. The health page reads:

- Data and WAL file sizes: together these are the physical bytes considered by
  the storage budget. A missing WAL is zero; an unreadable file is unknown.
- Allocated pages: SQLite's page count multiplied by page size.
- Reusable free pages: pages already freed by deletes and available for reuse.
- Pages in use: allocated pages minus reusable free pages.
- Journal and auto-vacuum modes, without changing either setting.

Data-file size and allocated pages can differ while changes remain in the WAL.
Free pages do not mean that the file has already shrunk. A large WAL can reflect
active readers or delayed checkpoints. These are observations, not a diagnosis
of the cause. The page never runs a checkpoint, vacuum, row count or repair.

Set an optional advisory budget in the initializer:

```ruby
Railwatch.configure do |c|
  c.telemetry_storage_budget_bytes = 2 * 1024 * 1024 * 1024
end
```

The environment variable is `RAILWATCH_TELEMETRY_STORAGE_BUDGET_BYTES`. The
default is unset. The example is a 2 GiB budget for the telemetry data file plus
WAL, not a recommended size for every application. Choose a budget below the
space reserved for telemetry, leaving room for WAL growth, other database
files, backups and temporary maintenance work. The export queue lives inside
the telemetry database and has its own admission limits as well.

Use a positive integer number of bytes. Unset, zero, negative, fractional or
malformed budgets leave the advisory budget disabled. Retention likewise
accepts positive integer days; invalid values preserve the seven-day default.

The page warns at 80% of the budget and requests action at 100%. **This is an
advisory limit, not a hard disk cap.** Reaching it does not reject ingest,
shorten retention, or delete recent telemetry. Check capture volume, sampling,
log volume and the prune schedule before changing retention. Existing pruning
continues to remove only data older than the configured retention window.
Changes to retention are an operator decision because they remove history.

This policy makes storage pressure visible without silently trading away
recent diagnostic evidence. Filesystem free space and a guaranteed maximum
database size are not measured or enforced by this page.

## Host capabilities and access

Railwatch Cloud calls the same `Railwatch::MonitoringHealth` reader with
`host: :cloud`. It binds the requested environment's tenant database, reads
Cloud ingest receipts for pending follow-ups, and uses the account's retention
period. Embedded writer, maintenance leases and export outbox are explicitly
not applicable. The hosting application's embedded configuration is never
used as the monitored tenant's settings. Paused Cloud ingestion is identified
as paused rather than flagged as unexpectedly stale.

The page uses the normal embedded dashboard authentication, or Cloud account
membership and environment scoping. It does not serialize database paths,
socket paths, export URLs, credentials, producer identifiers, lease owners,
delivery bodies or database exception messages. Opening it does not create a
missing telemetry database. Reads are bounded by fixed sample sizes, known
maintenance task names, indexed first-row lookups and SQLite metadata reads.

For configuration checks from the host, use `bin/rails railwatch:doctor`.
For export operations, use `bin/rails railwatch:export:status` and the export
commands described in [Embedded mode](embedded.md).
