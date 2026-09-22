# Proposal: shared PostgreSQL primary storage

**Status: feasibility design, not an available storage mode.** PostgreSQL can keep
Railwatch state in the host's existing database across several application servers.
The isolation primitives work; the adapter, migrations and concurrency guarantees
still need work. Runtime behavior and the dedicated SQLite default are unchanged.

| Layout | Current support | Proposal |
| --- | --- | --- |
| Two dedicated SQLite files; any supported host adapter | Supported local storage | Remains the default |
| Host's PostgreSQL primary; two owned schemas | Unsupported today | First implementation target |
| Host's SQLite primary | Unsupported | Deferred; separate files remain appropriate |
| MySQL or PostgreSQL-compatible third-party storage adapters | Unsupported | Outside this proposal |
| HTTP collector | No local storage required | Unchanged; no primary connection |

## Proposed opt-in and connections

```ruby
Railwatch.configure do |c|
  c.transport = :local
  c.storage = :primary # proposed; omitted/:dedicated keeps two SQLite files
  c.storage_connection_mode = :direct # proposed; :session_pool also accepted
end
```

Proposed environment setting: `RAILWATCH_STORAGE=primary`; generator command:
`bin/rails generate railwatch:install --local --storage=primary`. Fix selection
before models connect. Initial scope is one application environment per database
with fixed schema names; unrelated applications/environments cannot share them.

Resolve the current environment's Rails `primary` configuration, including its
resolved URL, TLS and credentials. Derive private `railwatch` and
`railwatch_telemetry` configurations from that target, overriding only Railwatch
connection settings. Do not change the host configuration, its search path, or
its migrations. Reject conflicting existing Railwatch configurations and any
non-PostgreSQL primary in this mode; never fall back to another connection.

Both aliases need `database_tasks: false`, `schema_dump: false`, no host migration
paths, and independent bounded pool/checkout/statement/lock timeouts. These flags
exclude aliases from standard Rails database tasks; they do not prevent the host
owner's normal `db:drop` from dropping the shared database. Lookups must include
hidden aliases; generator/boot-order tests must prove isolation before eager loading.

Keep two Railwatch pools separate from the host pool and from each other.
Telemetry transactions commit before permanent issue follow-ups, retaining the
existing receipt/retry boundary. Never inherit the host's `ApplicationRecord`,
reuse its checked-out connection, or switch its schema. A host rollback must not
undo committed telemetry. Each server can retain its local writer process/socket;
PostgreSQL coordinates writers across servers. Budget the extra connections per
process and server. A shared database still shares CPU, I/O, capacity and outages.
Initial support targets native PostgreSQL through direct or session-pooled
connections. Transaction-mode PgBouncer/proxies are a gated follow-up: session
`SET search_path` and other defaults may not survive between statements. Qualified
identifiers remain mandatory; prepared statements, timeouts and migration locking
also need pooler tests. Require an explicit connection-mode declaration when
detection is unavailable; visibly reject unknown or transaction-pooling modes.
URLs alone establish neither pooling mode nor dialect compatibility; native
PostgreSQL is required, with PostgreSQL-compatible services such as CockroachDB excluded.

## Owned schemas and migration history

| Owner | Relations | Migration bookkeeping |
| --- | --- | --- |
| Host | Existing schemas and tables | Existing ledgers and metadata |
| `railwatch` | Existing `railwatch_*` permanent tables; owned sequences/indexes | `railwatch.schema_migrations`, `railwatch.ar_internal_metadata` |
| `railwatch_telemetry` | Telemetry tables such as `queries`, `logs`, `sessions`, `people` | `railwatch_telemetry.schema_migrations`, `railwatch_telemetry.ar_internal_metadata` |

Set each Railwatch pool's search path to `pg_catalog`, its owned schema, then
`pg_temp`, with no `public`, `$user`, host schema, or other Railwatch schema.
Qualify model tables and raw relation references as well, so a missing owned
relation cannot resolve to a same-named public or temporary table. Quote schema
and relation identifiers separately. **Always schema-qualify DDL:** unqualified
`CREATE` would target `pg_catalog`. Keep logical names for mapper limits and wire
diagnostics; `Mapper::TEXT_LIMITS` currently uses `klass.table_name` and would break.

Tables, indexes, sequences, constraints and search objects stay inside their
owning schema, with no host foreign keys or cross-pool joins. First install accepts
absent or empty reserved schemas; reject nonempty schemas without recognized
Railwatch ownership metadata. A migration role needs owned-schema DDL privileges
(and schema creation permission for initial setup); a runtime role needs schema
usage, owned-table DML, sequence usage and catalog reads, not DDL. An optional
migration credential override must resolve to the same database. Reusing the host
URL retains that role's existing privileges, so namespacing is not a privilege
boundary. Do not change host grants or role defaults.

Add fresh PostgreSQL migration histories, proposed as
`db/railwatch_postgresql_migrate/` and `db/railwatch_telemetry_postgresql_migrate/`.
Do not replay or rewrite the SQLite migrations. In particular,
[`DropOrphanDurableIngestTables`](../db/railwatch_telemetry_migrate/20260914000000_drop_orphan_durable_ingest_tables.rb)
drops unqualified tables and deletes migration versions; the vacuum and FTS5
migrations also encode the dedicated-file layout. A PostgreSQL baseline must
create only its own schema objects and preserve the runtime contract.

The proposed explicit upgrade command is
`RAILS_ENV=production bin/rails railwatch:storage:migrate`. It may create the two
schemas within an **existing** database, but must never create, drop, reset or
recreate the database. Use independent `ActiveRecord::MigrationContext` instances
with explicitly schema-qualified `SchemaMigration` and `InternalMetadata`
objects; never change Active Record's global ledger names. Serialize competing
migrators with a Railwatch-owned database lock. Check permissions and ownership
before DDL, preserve host ledger rows even when version numbers coincide, and
report partial completion so the same task can resume. Boot and diagnostics do
not migrate. Host pending migrations retain Rails' normal failure behavior.

## Adapter and distributed-write work

| Area and current source | Required PostgreSQL behavior |
| --- | --- |
| [Ingest writer](../app/models/railwatch/ingest/writer.rb), [mapper](../app/models/railwatch/ingest/mapper.rb), [batch](../app/models/railwatch/ingest/batch.rb) | Validate `insert_all`/`ON CONFLICT` and `RETURNING` for new exception IDs, duplicate batches, query shapes and profile links. Use PostgreSQL `bigint` for signed-64-bit wire durations/counters: int32 microseconds overflow after 35.8 minutes. Preserve booleans, UTC microseconds and binary data. If using `jsonb`, handle `:jsonb` alongside `:json` without double encoding. |
| [Log search](../app/models/railwatch/telemetry/log.rb), [cursor paging](../app/models/railwatch/telemetry/cursor_page.rb) | Initial scope: bounded literal substring search using escaped `ILIKE`, with explicit case/Unicode/wildcard tests and no snippets. Test cursor ordering, including nulls. No FTS5 tables, rowid API or SQLite `INDEXED BY`; native PostgreSQL GIN search, phrase/prefix/exclusion parsing and snippets are follow-up work. |
| [Aggregations](../app/models/railwatch/telemetry/aggregations.rb), [tenant buckets](../app/models/railwatch/telemetry/tenant.rb), [health samples](../app/models/railwatch/telemetry/health_sample.rb), [scheduled executions](../app/models/railwatch/telemetry/execution.rb), [releases](../app/controllers/railwatch/releases_controller.rb) | Replace `strftime`/`json_extract` with adapter expressions; verify UTC boundaries, nearest-rank percentiles, JSON return types and strict grouping. Review date grouping in [issues](../app/controllers/railwatch/issues_controller.rb) too. |
| [People upsert](../app/models/railwatch/telemetry/person.rb), [export outbox](../lib/railwatch/export/outbox.rb) | Replace scalar `MAX(a,b)` with PostgreSQL `GREATEST`; qualify relation references and preserve null handling. |
| [Query resolution](../app/models/railwatch/telemetry/query.rb), [query shapes](../app/models/railwatch/telemetry/query_shape.rb), batch profile linking | Audit every raw table qualifier; model connection changes do not rewrite raw SQL. |

Centralize differences in a storage adapter contract. The generic insert fallback
does not establish PostgreSQL support. Any later native search index should be
database-maintained so inserts and deletes remain atomic.

SQLite's single-writer lock currently supplies synchronization that PostgreSQL
will not. These are correctness gates for a multi-server implementation:

- [RollupAbsorber](../app/models/railwatch/ingest/rollup_absorber.rb) reads, merges
  and upserts digest rows without locks. Establish missing rows with conflict-safe
  inserts, then lock affected rows in a consistent order before merging. The
  [reconciler](../app/jobs/railwatch/rollup_job.rb) must use the same coordination
  and avoid replacing rows from an unlocked stale snapshot. Test simultaneous
  first writes, existing buckets, and reconciliation during ingest.
- [Issue numbering](../app/models/railwatch/application.rb) uses `MAX(number)+1`.
  Use an owned PostgreSQL sequence or atomically updated counter. Issue creation,
  grouping and [follow-up receipts](../app/models/railwatch/followup_receipt.rb)
  need conflict-safe creation and locked updates in one permanent transaction.
- Lock the export destination before capacity checks and counter changes; use
  the same destination-before-delivery lock order in admission, completion,
  expiry and recount. Refresh accounting between selections. A rescued uniqueness
  violation aborts a PostgreSQL transaction unless isolated by a savepoint;
  audit [destination binding](../app/models/railwatch/telemetry/export_destination.rb)
  and outbox retry paths, preferring conflict-safe statements where possible.
- [Maintenance claims](../app/models/railwatch/maintenance_task.rb) and
  [export leases](../lib/railwatch/export/lease.rb) need database-time expiry,
  atomic claim/renewal and token/generation checks. A stale owner cannot release
  a replacement's lease or overwrite its result. Long tasks must renew or stop
  between bounded chunks; task mutations must remain safe if a lease expires.
  In-process throttles and one writer per machine do not coordinate a fleet.
- Recheck the batch ledger inside the protected transaction or handle a losing
  unique insert after rollback. Retry only the whole idempotent operation with
  bounded waits; do not hold database locks across network delivery. Exercise
  deadlock, connection-loss and retry paths with separate processes.

## Runtime guard, retention and health

Extend [RuntimeSchema](../lib/railwatch/runtime_schema.rb) through the adapter
contract. Explicit primary mode must verify the resolved target, both dedicated
pools, schema ownership, search paths, per-schema versions, required columns and
valid uniqueness constraints. Preserve the current pending/incompatible/
unavailable distinction and capture-pause/recovery behavior. PostgreSQL has no
SQLite `schema_version`: inspect bounded catalog metadata at each check rather
than trusting an unchanged migration ledger after manual DDL or a restore.
Clear model/mapper/search caches after validated recovery. HTTP collectors must
still perform no storage resolution unless a local dashboard is requested.

[Pruning](../app/jobs/railwatch/prune_telemetry_job.rb) may delete only owned rows
in bounded transactions, preserving session-hour and aggregate retention rules.
PostgreSQL autovacuum handles reclaimed tuples. Do not issue SQLite pragmas,
database-wide vacuum/analyze/checkpoint commands, change server tuning, or claim
that deletes immediately shrink disk use. The [optimizer](../app/jobs/railwatch/optimize_telemetry_job.rb)
and `railwatch:vacuum` need explicit adapter behavior; the latter must refuse the
shared PostgreSQL mode with applicable operator guidance.

[Monitoring health](../app/models/railwatch/monitoring_health.rb) needs a
PostgreSQL storage reader alongside its SQLite reader. Sum owned relation sizes
with indexes/TOAST counted once; label this telemetry relation storage, excluding
shared WAL and database-wide capacity. Apply any advisory budget to that stated
measurement, never the whole application database. Missing privileges produce
unknown, not zero. Keep reads bounded and report writer status per process/node;
a healthy local socket does not establish health across the fleet.

## Implementation and acceptance gates

1. **Configuration and migration isolation:** implement the resolver/adapter,
   model pool wiring, engine boot ordering, PostgreSQL baselines and custom task.
   Touch [configuration](../lib/railwatch/configuration.rb), [engine](../lib/railwatch/engine.rb),
   both [permanent](../app/models/railwatch/application_record.rb) and
   [telemetry](../app/models/railwatch/telemetry_record.rb) bases,
   [installer](../lib/generators/railwatch/install/install_generator.rb) and
   [tasks](../lib/tasks/railwatch_tasks.rake). Prove task exclusion and real Rails
   migration behavior before enabling capture.
2. **End-to-end adapter:** implement the SQL, serialization, locking, runtime
   guard, retention and health changes above. Run the real embedded pipeline
   against PostgreSQL through both local transport and the writer process.
3. **Release gate:** pass the matrix below on supported Rails/PostgreSQL versions
   and any claimed connection-pooler mode. Document pool budgets, failure behavior
   and upgrade policy. Keep current SQLite and HTTP-collector checks passing.

| Acceptance scenario | Required evidence |
| --- | --- |
| Namespace collision | Host `queries`, `logs`, `sessions`, orphan-migration names, indexes and sentinel rows stay unchanged; missing owned tables cannot fall back to public or temporary tables. |
| Migration ownership | Coincident version IDs and host metadata survive; repeated and competing migrators converge; aliases cannot create/drop/reset primary; host pending migrations still fail. |
| Host transaction | Commit/rollback and failure in either pool leave the other transaction independent; bounded Railwatch lock waits do not enlist host work. |
| Ingest and replay | Every wire kind, limits, JSON/binary payloads, exception IDs, query shapes, profile links, issue receipts and export dispositions survive retries and crashes without duplication. |
| Multiple servers | Simultaneous batch replay, rollup merges, issue allocation, export capacity/claims, maintenance expiry and stale owners preserve counts and ownership. |
| Dashboard and retention | Literal substring search, escaped wildcards/case behavior, filters, pagination, UTC buckets and aggregates agree with fixtures; pruning touches only owned data and emits no database-wide maintenance. |
| Runtime recovery | Missing schema/column/index, wrong ownership, revoked access, outage and repair pause safely and recover on every node; no request or diagnostics endpoint performs DDL. |
| Operations and regression | Backup/restore keeps both schemas and ledgers consistent; unavailable size metrics are unknown; SQLite default, package boot and HTTP collector remain unchanged. |

## Evidence and existing-install boundaries

Run `ruby script/probe_shared_primary_postgres` as an ordinary user with `initdb`,
`pg_ctl` and `psql` available. The [probe](../script/probe_shared_primary_postgres)
passed on PostgreSQL 18.6 in a disposable Unix-socket-only cluster. It ignores
`DATABASE_URL` and never connects to an existing database. It proves owned-schema
lookup, isolated ledgers/host metadata, an independent commit during host rollback,
one lease winner from two contenders, and failure without public-table fallback.
It does **not** test Rails aliases/migrations, Railwatch ingest, rollups, search,
retention, timeouts, privileges, poolers, lease recovery, or production throughput.

First implementation: fresh installations only. Changing a URL or setting must
not switch an existing installation. A future migration tool needs a controlled
writer stop, staged import, ID/sequence/count/receipt verification, fleet-wide
switch and rollback with preserved files. Shared storage joins the host's backup
lifecycle. Match fleet storage settings and gem versions; prove rolling upgrades separately.
