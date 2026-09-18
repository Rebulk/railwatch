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
```

Restart the app and open `/railwatch`. Then `bin/rails railwatch:doctor`
checks the wiring. The generator creates and migrates both databases
itself; `bin/rails db:prepare`, which a deploy already runs, migrates
them after every gem update.

The engine needs Active Job (its grouping and scan jobs are Active Job
classes even though embedded mode calls them directly) and loads it
itself. Action Cable is optional: with it the dashboard updates live,
without it (`rails new --minimal`) the pages refresh on navigation.

The two databases are SQLite files whatever your application's own
database is, so the generated entries name `adapter: sqlite3` rather than
inheriting your default. On a PostgreSQL or MySQL app the generator adds
`gem "sqlite3"` for them and asks you to `bundle install` before
`bin/rails db:prepare`.

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

The dashboard shows every query, log line and exception your app
produced, so it works the way Mission Control Jobs does: **HTTP Basic
authentication is on and closed by default**. With no credentials
configured every dashboard request is 401, and `railwatch:doctor` says
so. Set them with

```sh
bin/rails railwatch:authentication:configure
RAILS_ENV=production bin/rails railwatch:authentication:configure
```

which writes them to that environment's Rails credentials:

```yml
railwatch:
  http_basic_auth_user: ops
  http_basic_auth_password: secret
```

`RAILWATCH_HTTP_BASIC_AUTH_USER` and `RAILWATCH_HTTP_BASIC_AUTH_PASSWORD`,
or `c.http_basic_auth_user =` / `c.http_basic_auth_password =` in the
initializer, do the same. The live-update channel checks the same
credentials (the browser sends them on the WebSocket handshake).

### Your own authentication

Two ways, both from Mission Control's playbook. Either lets an admin of
your app in with no second password. Turn Basic off when you use one,
or both gates apply.

A base controller. Every dashboard controller inherits from it, so its
`before_action` runs first:

```ruby
c.http_basic_auth_enabled = false
c.base_controller_class = "AdminController"   # requires an admin, or redirects to sign-in
```

Your controller's code runs inside the engine, whose route helpers take
precedence; reach your app's with `main_app.root_path`.

Or a routes constraint, which keeps the engine out of it entirely (for
example with the sessions Rails' authentication generator creates):

```ruby
# config/routes.rb
constraints ->(request) { Session.find_by(id: request.cookie_jar.signed[:session_id])&.user&.admin? } do
  mount Railwatch::Engine, at: "/railwatch"
end
```

Requests that fail the constraint never reach the engine. A constraint is
invisible to the gem, though, so say that the engine's own gate is off on
purpose:

```ruby
c.http_basic_auth_enabled = false
c.dashboard_open = true   # "something in front of the mount gates this"
```

### Deliberately public

A dashboard on a private network or behind a VPN can be open, and saying
so is a setting rather than an omission:

```ruby
c.http_basic_auth_enabled = false
c.dashboard_open = true
```

With Basic off and none of `base_controller_class`, `dashboard_user` or
`dashboard_open` set, the gem cannot tell a deliberate choice from a
forgotten one. It serves the dashboard (a routes constraint it cannot see
is a legitimate answer) but logs a warning at every boot outside
development, `railwatch:doctor` reports the gate as undeclared, and live
updates are refused. Declaring any of the three settles it.

### Live updates and `/cable`

Action Cable runs on your application's own `/cable` endpoint, not under
the engine's mount, so a routes constraint around `/railwatch` does not
cover it and a base controller cannot reach it. The live-update channel
therefore follows what you declared: HTTP Basic credentials are checked
on the WebSocket handshake, a `dashboard_user` resolver is consulted,
`dashboard_open` and `base_controller_class` are taken at their word, and
an undeclared gate is refused. The channel carries an ingest ping (a
timestamp and per-type counts) and never telemetry records.

### Naming the operator

Comments, saved views and issue activity record who did them. Give the
initializer a resolver and the dashboard shows that person instead of a
single "Operator":

```ruby
c.dashboard_user = ->(request) do
  user = User.find_by(id: request.session[:user_id])
  user && { id: user.id, name: user.name, email: user.email }
end
```

## The writer process

Puma forks one Railwatch writer from its master when `config/puma.rb`
carries the plugin (`--local` adds it):

```ruby
plugin :railwatch if defined?(Railwatch)
```

Every web worker keeps its reporter thread, but instead of writing
SQLite it hands each batch to the writer over a Unix socket
(`tmp/sockets/railwatch-writer.sock`, `RAILWATCH_WRITER_SOCKET`). The
socket's directory is created mode 0700 and the socket 0600, so only
the app's own user can reach it; keep it that way if you move it. Linux
caps the whole path at 108 bytes, so an app checked out deep in the
filesystem should point this at a directory of its own under
`/run/user/$UID` or `/tmp` (not a bare file in `/tmp`). Single and
cluster mode alike: a default Rails 8 app runs Puma with no workers, and
its batches come off its request threads just the same. The
writer maps the records, writes both databases, folds the rollups,
groups exceptions into issues and runs the maintenance clock below. It
is the only process that ever holds the telemetry database's write lock,
and its Ruby interpreter is its own, so none of that work is ever
interleaved with a request. Same shape as Solid Queue's
`solid_queue_mode :fork`: it exits when Puma does, and Puma restarts it
if it dies. While it is down the reporter keeps batches in memory, with
the same byte ceiling and backoff as the HTTP transport, and every
batch carries an id the writer records inside the write transaction, so
a batch delivered twice is written once.

The writer judges its own health. A single batch write that runs past
sixty seconds is a stuck writer, not a slow one (a lock that never
clears, a lost connection), and the process exits so Puma restarts it;
the batch is retained on the worker and written by the new writer. The
doctor reports both whether the socket answers and when the last batch
was actually written, since a process that is alive and a process that
is doing its job are different questions.

Whether a writer is expected decides what a missing one means. Puma
workers under the plugin expect one: a socket that is absent or not
answering is a writer that is starting or restarting, and they retain
batches and retry for as long as it takes. A process with no plugin
(`bin/rails runner`, a Solid Queue worker, a `rails server` without it,
the test suite) expects none, says so once under `RAILWATCH_DEBUG`, and
writes its batches in-process instead. That fallback is provisional: the
socket is tried again every 30 seconds, so a process that started before
the writer did hands the work back as soon as one is listening. What
changes is which process pays for the write, not whether the write
happens.

Retention while a writer is away is bounded, not infinite. A writer that
is restarting is back in seconds; one that is missing for a minute (an
unwritable socket directory, a fork that keeps failing) is treated as
absent and the worker writes its own batches again, still re-checking, so
the records are kept rather than retained to the reporter's retry cap. A
batch that does exhaust that ladder is counted as dropped and reported
through `Railwatch.on_unrecoverable`, so loss is never silent. A Puma
phased restart stops the writer and starts a fresh one once the new
workers are up.

## Maintenance

Railwatch needs no job worker and nothing in `config/recurring.yml`.
The work that keeps the dashboard current happens in two places:

- **As each batch lands.** The writer writes the batch, folds its rows
  into the hour's rollups, and groups any exceptions into issues, all
  before it picks up the next batch. Counts, percentiles and the issues
  list move with every batch.
- **On Railwatch's own clock.** The writer runs a `railwatch-maintenance`
  thread that wakes every 30 seconds. Without a writer, every web and
  worker process runs one, and one process at a time runs each task,
  claimed through a lease row in the `railwatch` database, so a Puma
  cluster and a Solid Queue worker on the same server do not all prune
  at once.

| Task | Cadence | What it does |
| --- | --- | --- |
| drain follow-ups | every minute | Finishes the exception grouping of any batch whose process died right after the batch committed |
| release health | every minute | Hourly crash-free aggregates for the current and previous hour |
| rollup reconcile | hourly | Recomputes the previous hour's rollups from raw rows, for records that arrived after their hour closed |
| performance scan | every 5 minutes | Threshold breaches become issues |
| anomaly scan | every 5 minutes | Anomaly rules, when any are enabled |
| scheduled tasks | every 10 minutes | Missed and late scheduled tasks |
| auto-resolve | daily | Resolves issues quiet for 14 days |
| prune | daily | Deletes telemetry older than `retention_days`, then `ANALYZE` |

Because the clock lives in the web process, it keeps running when the
job worker is down, which is exactly when "scheduled task X missed its
run" needs to be raised. With Solid Queue, the issue also says which of
three things happened: the scheduler never enqueued the run, it was
enqueued but no worker is running, or a worker is alive and it is
waiting behind a backlog.

Every batch is written exactly once. The reporter gives each batch an
id before its first attempt and the write records it in the same
transaction as the rows, so a write that fails (the file locked by a
backup, say) is retried with backoff and a retry of a batch that did
commit is a no-op. `bin/rails railwatch:doctor` reports the last
tick. If you installed a pre-release that added `Railwatch::*` entries to
`config/recurring.yml`, remove them; the doctor says so too.

## Settings

```ruby
Railwatch.configure do |c|
  c.transport = :local            # RAILWATCH_TRANSPORT=local
  c.issue_prefix = "SHOP"         # RAILWATCH_ISSUE_PREFIX; keys like SHOP-12
  c.repository_url = "https://github.com/you/shop"  # RAILWATCH_REPOSITORY_URL
  c.retention_days = 7            # RAILWATCH_RETENTION_DAYS
  c.http_basic_auth_enabled = true    # RAILWATCH_HTTP_BASIC_AUTH_ENABLED; credentials from Rails credentials or env
  c.base_controller_class = "ActionController::Base"  # RAILWATCH_BASE_CONTROLLER_CLASS
  c.dashboard_open = false            # RAILWATCH_DASHBOARD_OPEN; "yes, public, on purpose"
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
