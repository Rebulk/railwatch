# Changelog

## Unreleased

<!-- Pull requests add their entry here. The version number and the date are
     filled in by the release commit, which is also the only commit that
     touches lib/railwatch/version.rb and Gemfile.lock. See CONTRIBUTING.md. -->

## 0.7.0 (2026-09-23)

- The gem ships the dashboard's frontend source (`app/frontend`, without
  tests) alongside its build, and `Railwatch.frontend_path` points at it.
  Railwatch Cloud now builds its bundle from this source instead of
  keeping its own copy, so the dashboard has one author. A host
  application is unaffected: it still uses the prebuilt bundle and needs
  no Node. The package grows by about 300 KB.
- The gem no longer carries the cloud's hosting pages and components
  (marketing, sign-in, accounts, settings, usage, docs), which it never
  rendered, or eleven components no page used. Three unused Radix
  packages are removed from the dashboard build.

## 0.6.1 (2026-09-23)

- The docs describe embedded as the default install throughout: two
  commands, then optional Railwatch Cloud. They correct what 0.6.0 left
  stale: an embedded install needs no token; the PostgreSQL and MySQL
  steps; export needs a token first; a `dashboard_user` resolver names
  the operator but does not gate pages; the Puma plugin line must be
  unconditional; an embedded app's test databases need one
  `RAILS_ENV=test bin/rails db:prepare`. MCP is marked as a Railwatch
  Cloud feature. LLM calls are listed.
- The installer's embedded next steps say to get a token before turning
  on export.
- Draw the Trend sparklines. Recharts pads every side of a chart by 5px,
  which left the 32x10 table-cell sparkline a plot area 0px tall, so every
  Trend column on every page was blank.
- LLM calls: a failed call no longer counts as "unpriced". It used no
  tokens and has nothing to price, yet any failure made its model read
  "+N unpriced" beside a complete spend total; the Recent table shows "–"
  for it instead. The model and tool call charts label their bars ok /
  failed instead of HTTP status classes, and the Recent table's Call
  column truncates instead of pushing Detail off the right edge.
- Issues: the daily chart marks each deploy day with a line and names the
  deploys in the tooltip, instead of printing refs that overprint when
  several ship in a week.
- Jobs: the recent runs card keeps the job name readable. The exception
  truncates, and the origin user and tenant columns appear from 2xl up
  (the job class page shows them at every width).

## 0.6.0 (2026-09-22)

- Embedded is now the installer's default. `bin/rails generate
  railwatch:install` with no flags writes what `--local` used to: the
  `railwatch` and `railwatch_telemetry` SQLite databases, `plugin
  :railwatch` in `config/puma.rb`, and `c.transport = :local`, so two
  commands give a working dashboard at `/railwatch` with no account and no
  token. The cloud install is `--cloud`, and any option that only means
  something there (`--prompt-token`, `--token-stdin`, `--url`,
  `--kamal-secrets`) implies it, so existing cloud instructions keep
  working. An exported `RAILWATCH_TOKEN` on its own does not pick the
  cloud: a token in the shell is not a decision about where data goes.
  `--local` is gone (it is the default); the gem's runtime default when no
  initializer sets a transport is unchanged. The embedded next steps now
  end with how to mirror to Railwatch Cloud (`c.export_enabled`).

- The embedded dashboard is open in development when HTTP Basic has no
  credentials, so the first run needs no password step. Every other
  environment is unchanged: closed, 401, until credentials exist. That
  case now also logs a boot warning outside development and test (it was
  only in the doctor), since a 401 on a deployed dashboard otherwise looks
  like a broken install. Configured credentials apply in development too.

- Bound how long Puma waits for the embedded writer to stop. The plugin sent
  the writer TERM and then called `Process.wait` on it, which has no timeout:
  a writer that did not exit -- stuck in a SQLite write, on a full disk --
  held Puma's shutdown open for as long as it stayed stuck. Measured against
  a child that ignores TERM, the stop never returned (the harness gave up at
  10s with the child still alive). Puma now waits `shutdown_timeout` (2s),
  the same allowance it gives its own reporter, then KILLs the writer and
  reaps it, so a wedged writer costs a bounded 2s and never leaves a zombie.
  A writer killed mid-batch loses nothing -- the batch is retried by id
  against the next writer -- which is why the bound is not the writer's own
  worst-case drain (13s at the defaults): waiting for it would buy no data,
  only exit time, and that time counts against the container's stop grace.
  A writer that exits on TERM is let go the moment it does (measured
  ~50ms), and a pid the cluster has already reaped is still treated as gone.

- Make one HTTP attempt per delivery. `Transport::Http#deliver` retried a
  raised error or a 5xx once on its own, inside a reporter that already owns
  a retry ladder of eight attempts, so each rung cost two socket timeouts
  and the effective attempt count was about sixteen. Against a receiver that
  accepts connections and never answers, one delivery cost 6.0s; it now
  costs 3.0s (one `read_timeout`), and one attempt, like `deliver_encoded`.
  Response classification and `Retry-After` are unchanged: a 5xx or a raised
  error still comes back retryable and the reporter still schedules it.

- Correct `docs/configuration.md` and `docs/troubleshooting.md`, which told
  users to raise `buffer_size` under pressure. At the defaults the byte
  ceiling (`buffer_bytes`, 16 MiB) fills at roughly 5,000 records on a
  realistic mix, so the 10,000-record count is never reached and raising it
  changes nothing. The setting stays; the advice now points at `buffer_bytes`.

- Say so when records are lost. `Railwatch.on_unrecoverable` fell back to
  the debug log, so with no callback registered and `RAILWATCH_DEBUG` unset
  a batch dropped after its retry ladder, one the receiver permanently
  refused, or the records still unsent when `at_exit`'s bounded shutdown
  ran out of time all vanished without a word. Since 0.3.7 that shutdown is
  the only delivery a rake task or `rails runner` gets, so a cron job whose
  exception never reached the platform looked exactly like one that had
  nothing to report. Confirmed against a receiver that accepts and never
  answers: the process left inside `shutdown_timeout` carrying three unsent
  records and printed nothing.

  A `Reporter::DeliveryError` -- raised only once the records are already
  gone -- now prints one `[railwatch]` stderr line, and `warn_on_data_loss`
  (`RAILWATCH_WARN_ON_DATA_LOSS`) defaults to **on**. Silence was the wrong
  default: telemetry that disappears without a word looks exactly like
  having nothing to report, which is the one failure an operator cannot
  diagnose from the platform side, because the evidence is what went
  missing. One line a deploy is the whole cost, and it only ever appears
  when something was actually lost.

  Both ways out are named in the line itself, so nobody has to find this
  entry to stop it: a registered `on_unrecoverable` always wins, which is
  how an app routes the loss somewhere better (`Rails.error.report`), and
  `warn_on_data_loss = false` restores silence. Recovered internal errors (a
  subscriber that raised, a flush that will be retried) stay debug-only
  either way: the gem carried on and there is nothing for an operator to do.

- Report a lost batch outside the flush lock too. The fix above moved the
  callback out of `@mutex`, the inner lock -- but `Reporter#flush` holds
  `@flush_mutex` around the whole of `deliver_buffer`, and the give-up path,
  the permanent-rejection path and the rescue all report from inside it. A
  callback that asks this same reporter to flush (`Railwatch.flush` is public
  and documented) hit the same non-reentrant `Mutex` one level out: the same
  `ThreadError: deadlock; recursive locking`, rescued and hidden by
  `notify_unrecoverable`, so the callback ran halfway and reported nothing.
  The locked path now collects what it needs to report and `flush` hands it
  over once the lock is released. Found by CodeRabbit on this pull request.

- Report a given-up batch after releasing the reporter lock, not under it.
  `Reporter#retain` called `on_unrecoverable` inside `@mutex.synchronize`.
  The documented callback is `Rails.error.report`, whose subscriber records
  the error as an exception -- a write back into the same reporter, which
  takes `@mutex` to arm its thread or request a flush. That was
  `ThreadError: deadlock; recursive locking`, rescued and hidden by
  `notify_unrecoverable`, so the callback died halfway and the loss it was
  reporting was never seen. A callback that merely blocked held every
  request thread's `write_now` and `shutdown` itself behind it for the
  duration. `notify_unsent` and `delivery_rejected` already called out
  unlocked; this was the one that did not.

- Investigated and left alone: `Reporter#shutdown` after `thread.join`.
  The bookkeeping that follows the join (`pending_delivery`, the
  once-only notify latch) takes `@mutex` for microseconds and never does
  I/O -- measured 0.2ms over `shutdown_timeout` against a transport wedged
  forever. The only thing that can extend it is the operator's own
  callback, which runs once and is theirs to bound, as any `at_exit`
  handler is. Wrapping it in `Timeout` would trade a visible cost for a
  killed thread.


## 0.5.1 (2026-09-21)

Three small seams for a host that runs these models on its own routes and
migration history, found while Railwatch Cloud deleted its fork of them.

- `Railwatch.url_helpers` is where the models resolve the links they build
  (a trace from an execution page, a saved view's page). It is the engine's
  routes unless the host sets it to its own.
- `FilterQuery.filter_routes` narrows grouped route rows by `method:`,
  `route:`, and `status:`; it lived in the requests controller.
- The export queue migration is renumbered to 20260919000100. A host with
  a telemetry migration of its own at the old number would otherwise fail
  to run either.

## 0.5.0 (2026-09-21)

The telemetry layer the hosted platform runs is this gem's, not a copy. Everything
Railwatch Cloud had improved in its fork comes home, and the two seams the platform
needs are named.

- **Chart bucket widths.** `Telemetry::Aggregations` offers `STEPS` (1m to 1d),
  `default_step`, and `steps_for` a window; `series` takes a `step:` and reads raw
  rows with exact per-bucket percentiles under an hour, rollups at an hour and up;
  `fill` zero-fills quiet buckets. The dashboard shows a step picker beside the
  window picker, and every series page, release health, tenants, processes, and
  exceptions draw at the chosen step. Latency lines break over an empty bucket
  instead of dropping to zero.
- **One `Window`.** `Railwatch::Window` resolves `?window=` presets and custom
  `?from=&to=` ranges, with the previous period for deltas; the controller concern
  reads it instead of carrying the table.
- **Rollup extras.** `Telemetry::Rollup.summarize` merges each type's `extra`
  (LLM spend and tokens, cache hits and misses) the way `absorb!` does.
- **LLM thresholds and anomaly rules.** `spend`, `tokens`, and `truncation_rate`
  metrics on `llm_calls` and `llm_tools`; the form narrows metrics by kind and
  shows the unit; `Threshold#format_value` prints dollars and percentages.
- **`as_row`** on Execution, Log, Exception, and Query: the one row shape every
  list surface shows. The commands page reads the exit code from `status`.
- `Railwatch::TelemetryRecord` documents that the hosted platform tenants it, and
  `docs/embedded.md` says what the platform is in terms of this engine.

## 0.4.0 (2026-09-21)

The gem is the one author of what goes over the wire and what runs in the
browser. Anything that receives from it, Railwatch Cloud first, reads these
from the gem instead of keeping a copy.

- **One browser client.** The gem carried two: the install template wrote
  the `railwatch_session` cookie that `Railwatch::Sessions` reads, while the
  dashboard's own copy still wrote `lantern_session`, so every embedded
  dashboard shipped a beacon whose sessions never stitched to their server
  requests. There is one file now, `app/frontend/lib/railwatch.ts`, shipped
  in the gem (`Railwatch.browser_client_path`): the dashboard bundle is built
  from it, `railwatch:install` copies it, and a host with its own frontend
  build imports it. A spec holds the cookie name to the regex.
- **Shipped wire fixtures.** `lib/railwatch/wire_fixtures.json` holds one
  record per type in `Railwatch::Record::VERSIONS`, produced by the gem's own
  subscribers and middleware, stabilized, and checked in.
  `Railwatch.wire_fixtures` loads it. A receiver tests its mapper against
  these rather than hand-writing what it remembers the gem sending. The spec
  that generates them fails when the file is stale; `rake
  railwatch:wire_fixtures` regenerates it, and that diff is the review
  surface for a wire change.
- **Record versions are enforced.** Every record has carried a `v` since the
  first release and no receiver read it. `Railwatch::Ingest::Mapper` now
  refuses a record whose version is not the one this gem emits for its type,
  by name (`log v2 is not v1`), on both the trusted embedded path and the
  untrusted one. A shape change without a version bump is caught by the
  fixture spec; a version bump the receiver has not shipped is refused
  instead of misread.
- `Railwatch::Transport::Http::HEADERS` names the delivery headers in one
  place for the receiver to read.

## 0.3.7 (2026-09-20)

- Stop a rake task or `rails runner` waiting on the network as it finishes.
  The command patches called `Railwatch.flush` when the execution closed --
  on the application's own thread, with no time limit. The engine's `at_exit`
  already calls `Reporter#shutdown`, which wakes the reporter thread and joins
  it for `shutdown_timeout`, so the same records were already being delivered,
  already bounded, and a failed task's exception already went with them. The
  flush was a second, unbounded way to do it.

  Against a receiver that accepts connections and never answers, that second
  way cost a full timeout ladder per process -- measured at ~6s, and ~12s when
  it queued behind a delivery the reporter thread was already stuck in. An app
  whose container entrypoint boots Rails eleven times before starting Puma
  spent that on every boot and lost the deploy to its proxy's timeout. With
  the call removed the task returns immediately and the process still leaves
  within `shutdown_timeout`, carrying the same records.

  Only short-lived processes were affected: web and worker processes flush on
  the reporter's own thread and never blocked. `Railwatch.flush` is unchanged
  and still public, for a caller who wants to wait on purpose.

- Add a process-level regression that runs a failing rake task against a
  socket that accepts and never answers, and asserts the task returns without
  waiting on it and the process exits inside the shutdown bound. In-process
  examples cannot see this: the cost lives in a socket read and the bound in
  an `at_exit` join.

## 0.3.6 (2026-09-20)

- Harden embedded live-stream authorization and telemetry delivery. Bound
  source-file access and HTTP response reads.
- Simplify prelaunch interfaces: use prompt, stdin, or environment token input;
  pass the complete transport delivery metadata; use the current process-version
  field. Update public install examples and remove obsolete upgrade wording.

## 0.3.5 (2026-09-20)

- Make the embedded telemetry database give disk back. `PruneTelemetryJob`
  deleted rows past `retention_days` and nothing ever vacuumed, so the freed
  pages went on SQLite's freelist to be reused and never returned to the
  filesystem: the file only ever grew. Measured on a copy of a real production
  database of the same shape (bulk deletes, continuous inserts), deleting
  40,148 rows left the file at 21M with 5,164 pages on the freelist; a single
  `PRAGMA incremental_vacuum` took it to 44K.

  Two halves, and neither is worth anything alone. A new telemetry migration,
  `EnableIncrementalVacuum`, puts the database into `auto_vacuum=incremental`;
  and the nightly prune now runs `PRAGMA incremental_vacuum` after its deletes,
  bounded to 2,000 pages a slice and 25 slices (~200MB at SQLite's 4K default)
  so a backlog drains over successive nights instead of stalling one.

  The mode cannot be declared in `config/database.yml`: Rails applies its own
  `DEFAULT_PRAGMAS` before any you declare, and `journal_mode = wal` writes the
  file header, so by the time `auto_vacuum` runs the database is no longer new
  and SQLite accepts the statement and ignores it. The migration is numbered
  below `CreateTelemetry` for the same reason -- it has to run while the file
  still holds nothing.

- Add `bin/rails railwatch:vacuum:status` and `bin/rails railwatch:vacuum`.
  An **existing** install cannot change mode without a full `VACUUM`, which
  rewrites the whole file with the write lock held, so nothing does that on its
  own: the migration leaves an existing database exactly as it found it.
  `railwatch:vacuum:status` reports the file, its size, its mode and its
  freelist and changes nothing; `railwatch:vacuum` says what the conversion
  will cost and then does it. Installs created from this version on need
  neither.

## 0.3.4 (2026-09-20)

- Fix the embedded dashboard offering its install steps to an install that is
  already reporting. `last_seen_at` was process-local state, set by whichever
  process ingested a batch. A deployed embedded install ingests in the writer
  process the Puma plugin forks and renders the dashboard in a web one, so the
  web process never saw it set and read the nil as "no events yet" -- add the
  gem, run the generator, set the token, run the doctor -- no matter how much
  had been recorded. It now reads the newest batch row from the telemetry
  database, which every process shares.
- Fix live updates never connecting. The channel asked for
  `connection.request`, which Action Cable defines below `private` for use
  inside a Connection subclass; from a channel it raises NoMethodError, so
  every subscribe failed and the dashboard sat on "Disconnected" while the
  client retried. It now builds the request from the connection's public `env`.
- Add the gem's first channel spec, with a connection stub that mirrors
  ActionCable::Connection::Base's real method visibility. Action Cable's own
  ConnectionStub defines neither `request` nor `env`, so a stub that exposed a
  public `request` would have agreed with the broken code.

## 0.3.3 (2026-09-19)

- Fix `railwatch:install --local` writing test databases that parallel test
  runners cannot share. The generated `test` entries named
  `storage/test_railwatch*.sqlite3` with no `TEST_ENV_NUMBER`, so every worker
  in a parallel run opened the same two SQLite files and raced through them:
  `ActiveRecord::PendingMigrationError` and `SQLite3::IOException: disk I/O
  error` out of `configure_connection`, on every shard. Rails' own test
  database naming carries the number for this reason, and the generated names
  now do too. An app with no parallel runner sets no `TEST_ENV_NUMBER`, so its
  generated file is unchanged and no existing install needs migrating.

## 0.3.2 (2026-09-19)

- Fix an embedded install's rake tasks reporting over HTTP instead of into
  the app's own database. A rake process invokes its top-level task -- where
  the command patch starts the execution, and sampling it builds the
  reporter -- before that task's `:environment` prerequisite boots Rails and
  runs `config/initializers`. A token in the environment is enough for
  Railwatch to be enabled that early, so the reporter chose HTTP from a
  config that had not yet been told the app is embedded, and kept it.
  Every rake task's telemetry then went to the receiver instead of the
  local database, skipping the export queue and the replay receipt it
  earns. Affects embedded and hybrid installs with a token configured;
  cloud-only installs were never affected, and neither was an embedded
  install with no token.
- The reporter now re-decides what it derived from a not-yet-final config
  once `config/initializers` has run: its transport, and its buffer size
  while that buffer is still empty.
- Add a subprocess regression that reproduces rake's ordering and fails if
  an embedded app's rake task reports over HTTP.

## 0.3.1 (2026-09-19)

- Fix production boot for cloud-only installs with no Railwatch databases.
  Versions 0.2.0 through 0.3.0 eagerly loaded embedded models even when
  reporting over HTTP. Hosts using `activerecord-tenanted` (or disabling
  `active_record.check_schema_cache_dump_version`) then failed with
  `Railwatch::DatabaseNotConfigured` when Rails inspected their connection
  pools. Hosts without Solid Queue also failed while loading embedded jobs.
  HTTP installs now leave embedded models, jobs and dashboard controllers
  out of eager loading; the browser beacon and HTTP reporting still work.
  `transport = :local` keeps its existing eager loading and database guards.
- Add production subprocess regressions with only a primary database,
  checking boot, health, browser beacons and HTTP exception delivery without
  loading `TelemetryRecord` or any embedded database model.

## 0.3.0 (2026-09-19)

- An embedded install can now also mirror its telemetry to Railwatch Cloud,
  or to any receiver speaking the same protocol. It is off unless you ask
  for it: `c.export_enabled = true` (or `RAILWATCH_EXPORT_ENABLED=true`),
  reusing the token and ingest URL you already have. A token being present
  is not consent -- an embedded install that has one configured still sends
  nothing.

  Records are held in a durable queue in your own telemetry database,
  admitted in the same transaction as the rows they mirror, and sent by one
  leased thread. A delivery keeps the exact bytes it will send until the
  receiver acknowledges it, so a retry is the same delivery rather than a
  second one; the receiver recognises repeats and answers with the original
  counts. Local capture never waits on the network, and a queue that cannot
  drain sheds rather than growing without limit. `railwatch:export:status`
  shows what is queued; `railwatch:doctor` reports export health, and fails
  if you asked for mirroring and it cannot work.

  Embedded and cloud installs are otherwise unchanged: same install, same
  records, same dashboard. See docs/embedded.md.

- Ingest acknowledgements are read more carefully. An all-zero
  acknowledgement with no reason no longer counts as a successful delivery
  for a non-empty batch -- nothing legitimate answers a 500-record batch
  that way, but a proxy error page does, and those were being treated as
  stored. A paused or over-quota environment still takes the batch rather
  than burning the retry ladder, and now says so rather than looking like
  storage.

## 0.2.2 (2026-09-18)

- README: describe embedded mode. The gem has had two destinations since
  0.2.0, and the front page still read as though Railwatch Cloud were the
  only one.

## 0.2.1 (2026-09-18)

- No change to the gem itself. This release exists to run the automated
  publish path end to end: 0.2.0 went out from a laptop, and this one is
  pushed by `release.yml` on a tag, authenticated by GitHub OIDC rather
  than an API key stored anywhere.
- Releases are now cut without a stored RubyGems credential (trusted
  publishing). `gh workflow run release.yml` answers "would a tag publish
  right now?" in a few seconds, without building or publishing anything.
- `spec/railwatch/gemfile_lock_spec.rb` checks the *committed*
  `Gemfile.lock` against the gemspec, because `bundle exec` repairs the
  working copy before the suite starts while CI installs frozen and fails
  first. A stale lockfile now fails locally, where it is one commit to fix.

## 0.2.0 (2026-09-18)

- Embedded mode: `bin/rails generate railwatch:install --local` keeps
  every record in two SQLite databases the app owns (`railwatch` for
  issues, comments, saved views, thresholds and deploys;
  `railwatch_telemetry` for what the app reports) and serves the whole
  Railwatch dashboard at `/railwatch`, from a bundle shipped inside the
  gem. No token, no Node, no asset pipeline. `c.transport = :local`
  (`RAILWATCH_TRANSPORT=local`) switches the reporter to write batches
  in-process; everything else about sampling, redaction and buffering is
  unchanged. The installer adds the databases (migrated from the gem's own
  migration history, so a gem update is followed by `db:prepare` and
  nothing else) and an
  initializer with `issue_prefix`, `repository_url`, `retention_days`
  and a `dashboard_user` resolver. `railwatch:doctor`, `railwatch:status`
  and `railwatch:deploy` understand the mode. See docs/embedded.md.
- Embedded mode needs no job worker. Exceptions are grouped into issues
  as each batch lands, and release health, threshold and anomaly scans,
  missed scheduled tasks, auto-resolve and pruning run from
  `Railwatch::Maintenance`, a clocked thread in every web and worker
  process (one process per server runs each task, leased through the new
  `railwatch_maintenance_tasks` table). Nothing goes through Active Job,
  so the gem never writes the host's queue adapter, and a dead worker
  cannot hide its own missed runs. The installer no longer edits
  `config/recurring.yml`; remove any `Railwatch::*` entries a pre-release
  added there.
- Embedded ingest folds each batch into the hourly rollups as it lands
  (`Ingest::RollupAbsorber`), so the dashboard's counts and percentiles
  move with every batch; the hosted platform's per-batch RollupJob
  recompute is not enqueued in embedded mode and the minute-long
  aggregate cache is bypassed there.
- Embedded mode gets a writer process. `plugin :railwatch` in
  `config/puma.rb` (added by `--local`) forks one `Railwatch::Writer`
  from the Puma master, the way Solid Queue's in-Puma mode does. Web
  workers hand their batches to it over a Unix socket
  (`Transport::Socket`) instead of writing SQLite on their own reporter
  thread, so mapping, the write lock, rollups, issue grouping and the
  maintenance clock all run in a process whose interpreter no request
  shares. The writer is restarted by Puma if it dies and stops with it;
  a process with no writer (a runner, a Solid Queue worker, a server
  without the plugin) writes in-process from its first miss. The doctor
  reports whether the writer is listening. Measured
  on a two-worker Puma host under five minutes of open-loop load with
  every record sampled: all-paths p95 817 ms with the writer against
  938 ms writing on the worker threads and 716 ms with Railwatch off, and
  each worker's reporter thread fell from 7 s of CPU per minute of load
  to 2 s over the whole run.
- Hardening from an adversarial review of the writer: a batch's
  exceptions are counted onto an issue exactly once however many times
  its follow-ups run (a `railwatch_followup_receipts` row per batch and
  group, committed with the count); the wedge guard tracks each write by
  invocation so a retry of the same batch cannot hide a stuck original;
  the writer reads and writes under deadlines, bounds inflation and the
  accept queue, binds inside a 0700 directory as a 0600 socket, and
  refuses to take over a socket another writer is answering on; Puma
  phased restarts restart the writer rather than losing it; workers
  under the plugin retain batches while the writer is away, and any
  other process falls back to in-process writing on the first miss
  (including a stale socket file); a maintenance lease is released only
  by the token that claimed it and a failed task is retried next tick;
  maintenance failures report through `on_unrecoverable`, never
  `Rails.error`; pruning is bounded per run. The plugin is cluster-mode
  only.
- Embedded ingest keeps a delivery ledger. The reporter's batch id is
  stored on the `ingest_batches` row inside the batch's own transaction,
  so a batch the reporter retries after a failure is written once, and
  a write that fails is now retried with the same backoff the HTTP
  transport gets instead of being dropped. The exception grouping a
  batch owes is recorded on that row as well and cleared when done; a
  process that dies in between leaves it for `Railwatch::Maintenance` to
  finish on its next tick, so an exception can no longer be stored
  without ever becoming an issue.
- A missed scheduled task says why, when Solid Queue is the adapter:
  the scheduler never enqueued the run, it was enqueued but no worker
  is running, or it is enqueued and waiting behind a backlog. Read from
  Solid Queue's own `recurring_executions` and `processes` tables.
- `rails runner script/x.rb` is a deployed script even when the whole
  application is checked out under a scratch directory such as `/tmp`;
  only a scratch path inside the app still counts as interactive.
- `RollupJob` no longer overwrites a rollup that a batch folded into
  between its read and its write: a stored count higher than the
  recomputed one is kept, and the next run picks the group up.
- `PruneTelemetryJob` takes `checkpoint:`; the embedded clock prunes with
  a PASSIVE WAL checkpoint so it never blocks the app's own readers.
- The affected-user count on an issue is recomputed at most once every
  five minutes per issue (and always for a new one) instead of on every
  batch that touched the group.
- The gem now depends on `inertia_rails` and `tdigest` for the dashboard.
- Embedded install is one command and boots in production. `bin/rails
  generate railwatch:install --local` now creates and migrates both
  databases itself (no separate `db:prepare`), fills in the production
  `database:` paths Rails 8.1's template leaves commented out. The two
  entries name `adapter: sqlite3` themselves instead of inheriting the
  app's default, so embedded mode works on a PostgreSQL or MySQL app (the
  generator adds `gem "sqlite3"` there and asks for a `bundle install`
  first) and needs no `&default` anchor to exist. The gem
  depends on `json < 3` for now: Rails 8.1 cannot decode with json 3
  (rails/rails#58784), which broke this gem's own SQLite migrations on a
  fresh Ruby 3.4.10, and a dependency is what makes `bundle add
  railwatch` resolve past it. The engine loads Active Job itself
  and treats Action Cable as optional, so an app from `rails new
  --minimal` boots with it.
- The engine's models never fall back to the host's primary database. Both
  abstract bases rescue a missing `database.yml` entry so a cloud-transport
  app still boots and eager-loads them, but using one then raises
  `Railwatch::DatabaseNotConfigured` instead of inheriting
  `ActiveRecord::Base`'s connection -- where the unprefixed telemetry
  tables (`sessions`, `visits`, `people`, `notifications`) are the
  application's own.
- The in-process fallback is provisional: a process that found no writer
  re-checks the socket every 30 seconds instead of writing its own batches
  for the rest of its life, and a process that expects a writer stops
  retaining and writes its own after a minute without one, rather than
  holding batches until the retry cap drops them. A batch abandoned after the retry cap is now
  reported through `on_unrecoverable` rather than only under
  `RAILWATCH_DEBUG`, and `railwatch:doctor` no longer calls a configured
  but absent writer a pass.
- The generated Puma line is `plugin :railwatch`, unconditional:
  `bundle exec puma` evaluates `config/puma.rb` before it loads the app,
  so the old `if defined?(Railwatch)` guard meant a writer was never
  started there. The plugin itself now decides whether to run after boot.
- Embedded mode is verified on PostgreSQL and MySQL hosts, not only
  SQLite ones. The telemetry databases are SQLite files whatever the
  application runs on, so the install is `generate`, `bundle install`
  (for the sqlite3 gem the generator adds), then `db:prepare`. On both,
  the app's own databases keep every table they had and the server gains
  no Railwatch table at all.
- Releasing is gated on the thing that silently breaks it. `gem build`
  globs its file list, so a missing or half-built dashboard produces a
  gem that installs cleanly and serves a blank page; `rake
  package:assert_dashboard` refuses to publish one, and the release
  workflow runs it between building the bundle and building the gem. The
  publish job also installs the bundle it was already calling `bundle
  exec` against, which it had never done. Built `.gem` files are no
  longer tracked in git.
- The browser beacon is bounded the way a hosted product bounds a public
  ingest endpoint, since one cannot hold a credential the page does not
  already give away: an origin allowlist (`beacon_allowed_origins`,
  same-origin by default, the analogue of Sentry's allowed domains), the
  per-client rate limit, and a new ceiling for the endpoint as a whole
  (`beacon_global_rate_limit`, 6,000/minute) so a rotating address cannot
  multiply past the first. Both limits fail closed on a cache store that
  cannot count, where the limiter used to fail open.
- How the dashboard is gated is now something the app states rather than
  something the gem guesses. `Configuration#dashboard_gate` names it:
  HTTP Basic, a `base_controller_class`, a `dashboard_user` resolver that
  can refuse, or `dashboard_open = true` for a dashboard that is public on
  purpose (a private network, a VPN, a routes constraint the gem cannot
  see). With Basic off and none of them set the gate is undeclared: the
  dashboard still serves, because a constraint is a legitimate answer, but
  the app logs a warning at every boot outside development, the doctor
  reports it, and live updates are refused. The live channel follows the
  declared gate, which matters because Action Cable runs on the host's own
  `/cable` endpoint that no routes constraint around the mount covers.
- Railwatch no longer pins `json` for the host. The Rails 8.1 and json 3
  incompatibility (rails/rails#58784) is the application's own, and a
  gemspec dependency would constrain every bundle for it. The gem detects
  the pair by asking it to decode rather than by comparing version
  numbers, so a patched Rails or a backport is judged correctly and the
  warning goes quiet by itself when Rails ships the fix. The installer
  offers the pin in the app's Gemfile, the doctor reports it, and the app
  logs it once at boot.
- Both database bases also survive an entry whose adapter gem is not in
  the bundle yet (a `LoadError` rather than `AdapterNotSpecified`), which
  is the state a PostgreSQL app is in between the installer adding
  `gem "sqlite3"` and the `bundle install` that follows.
- Host user ids are opaque. The columns behind comments, issue activity,
  saved views and issue assignment were integers, which assumed every
  application numbers its users: an app with UUID primary keys could not
  write a comment at all, and one with ids past the signed range could
  not either. They are strings now, a `dashboard_user` resolver may
  return whatever shape the app already uses, and rows written as numbers
  before the change still match the same person after it.
- The embedded dashboard authenticates the way Mission Control Jobs
  does: HTTP Basic is on and closed by default, so with no credentials
  every dashboard page answers 401 (with a note saying what to run), the
  live channel refuses the subscription, and the doctor reports it. The
  beacon endpoint and the dashboard's own static assets stay public, as
  they must be. `bin/rails
  railwatch:authentication:configure` writes
  `railwatch.http_basic_auth_user/_password` to the environment's Rails
  credentials; `RAILWATCH_HTTP_BASIC_AUTH_USER/_PASSWORD` or the
  initializer do the same. A host with its own admin auth sets
  `c.http_basic_auth_enabled = false` and either
  `c.base_controller_class` (the dashboard controllers inherit from it)
  or a routes constraint around the mount. Before this a production
  install served every query and log line to anyone who found the URL.
- The Puma plugin forks the writer in single mode too (the default for a
  Rails 8 app). It stops the writer from `at_exit`, after Puma's run loop
  has returned: Puma's SIGTERM trap fires `after_stopped` BEFORE it drains
  in-flight requests, so stopping there took the writer away from requests
  that were still running and lost their records. The live-update
  broadcast after a batch rescues a `LoadError` as well: a host whose
  production `cable.yml` names redis without the gem (Rails 8.1's
  non-Docker template) used to take the writer down on every batch.
- Puma workers under the plugin actually use the writer. The socket
  transport captured "is a writer expected" when it was built, and
  `rails server` builds the reporter (app boot) before Puma evaluates
  `config/puma.rb` (where the plugin sets the flag), so every worker
  inherited a transport that expected no writer, missed the socket once
  during the writer's startup, and wrote its own batches in-process for
  the rest of its life. The flag is now read at delivery time. On the
  dogfood host this is the difference between a reporter thread at 3.6 ms
  of CPU per request in each worker and one at 0.2 ms, with the writer
  process doing the 2.8 ms.
- The per-record memory estimate on the request thread
  (`Record.buffered_bytes`, run once for every query, cache event and log
  line an execution buffers) walks a record in one loop instead of one
  method call per value: 6.2 to 2.7 us for a query record, about 120 us
  off a 20-query request. Same numbers for every record shape, including
  at the depth bound and on a self-referential one.

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
  in likely secret-bearing files tracked by Git.

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
