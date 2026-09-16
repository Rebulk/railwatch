# Embedded mode: the dashboard inside your app

Railwatch can keep every record in your own application and serve the
full dashboard at `/railwatch`, with no token and no cloud. The gem's
reporter, buffer and sampling are the same; the only difference is
where a batch ends up. In embedded mode it is written straight into a
SQLite database your app owns, and the dashboard reads it back from
there.

Use it when one server runs the app. Telemetry lands in a file next to
your other SQLite databases, so several servers would each see only
their own slice. For more than one server, or for a team that wants one
place for many apps, point the gem at Railwatch Cloud instead
([Getting started](getting-started.md)); the two are switchable with
one setting.

## Install

```sh
bundle add railwatch
bin/rails generate railwatch:install --local
bin/rails db:prepare
```

Restart the app and open `/railwatch`. Then `bin/rails railwatch:doctor`
checks the wiring.

What `--local` writes, on top of the usual install:

- `config/initializers/railwatch.rb` with `c.transport = :local` and the
  dashboard's own paths excluded from request capture.
- Two databases in every environment of `config/database.yml`:
  `railwatch` (issues, comments, saved views, thresholds, deploys:
  small, permanent) and `railwatch_telemetry` (everything the app
  reports: written continuously, pruned nightly). A flat
  `development:` entry is nested under `primary:` first, since named
  databases need that form. Each entry's `migrations_paths` points into
  the gem, so `db:prepare` builds the tables from the gem's own
  migrations and nothing is copied into `db/`.
- The recurring jobs in `config/recurring.yml` (below).
- `mount Railwatch::Engine, at: "/railwatch"`, as always.

Nothing touches your primary database.

## Upgrading

The engine's tables migrate the way Active Storage's do: the migrations
live in the gem and each database's `migrations_paths` points at them.
After `bundle update railwatch`, run `bin/rails db:prepare` (or
`db:migrate`) and whatever is new applies; a deploy that already runs
one of those needs nothing extra. `bin/rails railwatch:doctor` reports
pending migrations for both databases. Tables in the `railwatch` file
are prefixed `railwatch_`; the telemetry file's tables are the hosted
platform's schema and are unprefixed.

## What you get

Every page of Railwatch Cloud: requests, jobs, scheduled tasks,
commands, queries, spans, exceptions, logs, cache, mail, notifications,
broadcasts, outgoing requests, LLM calls, storage, views, transactions,
deprecations, processes, releases, deploys, users, tenants, visits,
thresholds; issues with comments, assignment, merge and split; saved
views; alert rules and the alert log. Live updates arrive over Action
Cable when the app has it. The dashboard is a prebuilt bundle shipped
inside the gem, so the app needs no Node, no Vite and no asset pipeline
integration.

Not in embedded mode: accounts and members (the operator is whoever your
app lets through), integrations (alerts are recorded, not delivered),
and the MCP server.

## Authentication

The engine does not authenticate. Put the mount behind whatever your app
already uses:

```ruby
# config/routes.rb
authenticate :user, ->(u) { u.admin? } do   # Devise
  mount Railwatch::Engine, at: "/railwatch"
end
```

or a `constraints` block that reads your session. To name the person on
comments and saved views, give the initializer a resolver:

```ruby
c.dashboard_user = ->(request) do
  user = User.find_by(id: request.session[:user_id])
  user && { id: user.id, name: user.name, email: user.email }
end
```

Without one, the dashboard shows a single "Operator".

## Jobs

Rollups, issue detection and pruning are Active Job jobs, enqueued from
ingest and on a schedule. `--local` adds them to `config/recurring.yml`
for Solid Queue:

| Job | Schedule | What it does |
| --- | --- | --- |
| `Railwatch::RollupCatchupJob` | every minute | Reconciles the current and previous hour's rollups from raw rows |
| `Railwatch::PerformanceScanJob` | every 5 minutes | Threshold breaches become issues |
| `Railwatch::AnomalyScanJob` | every 5 minutes | Anomaly rules |
| `Railwatch::ScheduledTaskScanJob` | every 10 minutes | Missed and late scheduled tasks |
| `Railwatch::AutoResolveIssuesJob` | daily | Resolves issues quiet for 14 days |
| `Railwatch::PruneTelemetryJob` | daily | Deletes telemetry older than `retention_days` |
| `Railwatch::OptimizeTelemetryJob` | daily | `ANALYZE` on the telemetry database |

Run a Solid Queue worker, or set `SOLID_QUEUE_IN_PUMA=1` to run it
inside Puma on a single server. Rollups themselves do not need a job:
each batch folds its rows into the hour's rollups as it is written, so
counts and percentiles on the dashboard move with every batch. The
catch-up job only reconciles. Without a worker an app still gets live
rollups but not the scheduled scans that turn thresholds into issues.

## Settings

```ruby
Railwatch.configure do |c|
  c.transport = :local            # RAILWATCH_TRANSPORT=local
  c.issue_prefix = "SHOP"         # RAILWATCH_ISSUE_PREFIX; keys like SHOP-12
  c.repository_url = "https://github.com/you/shop"  # RAILWATCH_REPOSITORY_URL
  c.retention_days = 7            # RAILWATCH_RETENTION_DAYS
  c.dashboard_user = ->(request) { ... }
end
```

Every other option (sampling, redaction, ignored record types) applies
unchanged. The default samples every execution; set `c.sample` lower on
a busy app.

## Deploys

`bin/rails railwatch:deploy` records the marker in the app's own
database instead of posting it, and the Kamal post-deploy hook does the
same when `RAILWATCH_TRANSPORT=local` is set on the deployer.

## Storage and overhead

Telemetry is written by the reporter thread in batches, never on a
request. The cost on the request path is the same instrumentation the
cloud transport pays; the write itself adds under a millisecond at the
99th percentile at a hundred requests per second on a single Puma. The
telemetry database grows with traffic and sampling and is pruned to
`retention_days`; the `railwatch` database stays small. Both are plain
SQLite files in `storage/`, so Litestream or a volume snapshot covers
them.

## Switching to the cloud later

Set a token and drop `c.transport = :local` (or set
`RAILWATCH_TRANSPORT=http`). The local databases can stay; the dashboard
at `/railwatch` keeps reading what is there until it is pruned.
