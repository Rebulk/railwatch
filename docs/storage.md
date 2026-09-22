# Railwatch storage

Local Railwatch uses two dedicated SQLite databases. Keep this layout for new
and existing installs. The monitored application can use PostgreSQL, MySQL,
SQLite, or several named Rails databases; Railwatch records their queries and
stores the resulting telemetry in its own SQLite files.

| Database configuration | Contents | Lifetime |
| --- | --- | --- |
| `primary` and other host configurations | Application data | Managed by the application |
| `railwatch` | Issues, comments, deploys, saved views, rules, maintenance leases, follow-up receipts | Permanent Railwatch state |
| `railwatch_telemetry` | Executions, queries, logs, profiles, attachments, rollups, ingest ledger, export queue | Raw retention window; rollups retain 13 months; export deliveries have their own expiry |

The two Railwatch configuration names are fixed. Their file paths, directories,
pool sizes and timeouts are configurable. Additional host database names do not
require additional Railwatch telemetry databases. A local installation monitors
one application environment; it does not route telemetry to a different file
for each host connection or `app_tenant` value.

For example, keep the host's existing `primary` entry and add these siblings in
`config/database.yml`:

```yaml
production:
  primary:
    # Keep the application's existing adapter and connection settings here.
    url: <%= ENV.fetch("DATABASE_URL") %>
  railwatch:
    adapter: sqlite3
    database: storage/production_railwatch.sqlite3
    pool: 5
    timeout: 5000
    migrations_paths: <%= Railwatch.migrations_path(:railwatch) %>
  railwatch_telemetry:
    adapter: sqlite3
    database: storage/production_railwatch_telemetry.sqlite3
    pool: 5
    timeout: 5000
    migrations_paths: <%= Railwatch.migrations_path(:railwatch_telemetry) %>
```

Install the `sqlite3` adapter in the host's bundle even when its primary uses a
different adapter. Use durable storage visible to the local writer and web
processes. Every application environment needs its own pair of files. Relative
paths resolve from the Rails application root; absolute filesystem paths are
also supported. SQLite URI filenames and arbitrarily renamed configuration keys
are not supported. Give both files their own paths; pointing either name at the
host's database or at the other Railwatch file is rejected by the runtime guard.

Create and migrate only these databases with:

```sh
RAILS_ENV=production bin/rails db:create:railwatch db:migrate:railwatch
RAILS_ENV=production bin/rails db:create:railwatch_telemetry db:migrate:railwatch_telemetry
```

Later upgrades normally need only the two `db:migrate:<name>` tasks. The
authenticated dashboard identifies the database and exact pending migration
versions and prints commands for the current Rails environment. The gem does
not apply migrations during boot or capture.

## Runtime compatibility

Railwatch checks each database's own migration ledger against the migrations
shipped by the installed gem. Once versions match, it checks required table and
column names and the unique indexes that protect replay and updates. Missing
configuration, unsupported storage, pending migrations,
an incompatible restored schema, and an unavailable connection are distinct
states. A connection error means compatibility is unknown; it is not reported
as a pending migration. The check never borrows the host's primary connection
and does not create a missing database file.

An unsafe local schema pauses new capture, local ingest, writer ingest, export
delivery, and maintenance. Ordinary application requests keep working. Dashboard
authentication still runs first; an authenticated dashboard request receives
HTTP 503 with repair guidance and `Retry-After: 30`. Browser beacons retain their
normal validation and response behavior, and static dashboard assets remain
available. Telemetry generated while capture is paused is not recorded. Already
buffered batches retain the reporter's existing bounded retry policy.

An execution that starts during a detected schema outage, or spans an outage
observed by any thread in its process, stays suppressed through completion.
Repairing the schema resumes capture for new executions; it does not publish a
partially buffered execution. User pause/resume and sampling cannot override
this decision. An unhandled exception already handed to the reporter before the
outage was detected cannot be recalled. Checks are periodic, so an outage that
begins and ends between checks is not observed by this guard.

Checks are cached per process for 30 seconds. A successful check reuses its
table/column verification while the SQLite schema version and migration ledger
remain unchanged. After a migration or repair, the next check resumes capture
and clears stale model, mapper and full-text capability caches. Reloading Rails
or forking a worker invalidates the cache. For an immediate operator check:

```ruby
Railwatch::RuntimeSchema.status(force: true).as_json
```

An HTTP collector does not need either database and performs no schema checks
or local database connections. Requesting its embedded dashboard explicitly
checks the two local configurations, which is useful when viewing retained
local data after switching transport. Railwatch Cloud's tenant databases have
their own lifecycle; the embedded checker does not inspect them.

## Why primary-table storage is not supported

Telemetry tables are deliberately unprefixed: names include `queries`, `logs`,
`sessions`, `people`, and `executions`. They can collide with application tables.
Separate Rails connections and migration paths provide isolation; changing only
the database filename does not provide it. The permanent tables use the
`railwatch_` prefix, but their schema, leases, follow-up transactions and backups
are still managed as a separate database. Sharing either file would also mix
Railwatch's retention and disk-maintenance work with application data.

The storage implementation has several SQLite-specific parts:

- Ingest uses prepared SQLite statements, `INSERT OR IGNORE`, and inserted
  rowids. Its batch ledger and unique indexes make replay safe.
- Log search uses an external-content FTS5 index maintained alongside writes
  and pruning. A missing optional index falls back to text matching.
- Time bucket aggregation uses SQLite date functions. Migrations include FTS5
  and SQLite storage pragmas; retention uses WAL checkpoints and incremental
  vacuum to reclaim space.
- Railwatch Cloud isolates telemetry by environment through tenant connections;
  embedded `Environment#with_telemetry` uses one named database. The
  `app_tenant` column is a filter, not a replacement for database isolation.

An individual Active Record fallback for inserts does not establish support for
PostgreSQL or MySQL telemetry storage. Those adapters are supported for the
monitored application's data, not as Railwatch's local storage adapters. No
adapter-wide telemetry migration, search, aggregation, pruning, or replay
verification exists for them in the local installation.

A future storage option should first define an explicit adapter contract for
ingest, search, aggregation, schema checks, and retention; introduce a collision
free namespace and migration history; then verify each adapter through ingest,
replay, dashboard, retention, backup and recovery tests. Moving an existing
installation would need a staged export/import into a fresh target, count and
ledger verification, a controlled writer switch, and a rollback plan preserving
the original files. Pointing today's configuration at existing primary tables
is not a migration path.

The [shared PostgreSQL primary proposal](shared-primary-storage.md) assesses an
explicit opt-in for applications running on several servers. It describes the
required isolation, adapter work and acceptance tests; it is not an enabled
storage feature. The dedicated SQLite layout above remains the default.

See [embedded operation](embedded.md) for writer processes, retention and disk
reclamation, and [monitoring health](monitoring-health.md) for runtime status.
