# Railwatch, for coding agents

About *using* the `railwatch` gem from a Rails application; copy
this into that application's repository. Index of everything else:
[`llms.txt`](llms.txt).

Railwatch instruments a Rails app end to end and stores linked telemetry in
two SQLite databases of the app's own (embedded, the default) or sends it to
Railwatch Cloud. Every request, job attempt, scheduled task run, and command is
an **execution**; every query, cache read, log line, outgoing HTTP call, LLM
call, view render, exception, and span is a child of one, linked by
`execution_id`/`trace_id`. It never writes to the app's primary database.

## Install

```sh
bundle add railwatch
bin/rails generate railwatch:install                                 # embedded: dashboard at /railwatch
bin/rails generate railwatch:install --prompt-token --kamal-secrets  # or: Railwatch Cloud
```

With no flags the install is embedded (see [Embedded mode](docs/embedded.md)):
telemetry stays in two SQLite databases the app owns (`railwatch`,
`railwatch_telemetry`, added to `config/database.yml`), Puma forks one writer
for them (`plugin :railwatch` in `config/puma.rb`), and the dashboard is served
at `/railwatch`. It is open in development and answers 401 elsewhere until
`RAILS_ENV=production bin/rails railwatch:authentication:configure` sets a
password. An exported `RAILWATCH_TOKEN` alone does not change the mode.
`--cloud`, or any of `--prompt-token`, `--token-stdin`, `--url`,
`--kamal-secrets`, sends telemetry to Railwatch Cloud instead.

Both modes write `config/initializers/railwatch.rb`, mount `Railwatch::Engine`
at `/railwatch`, add the Kamal `post-deploy` hook and the Inertia browser client
where the app has them, and require `railwatch/rspec` (or `railwatch/minitest`)
in the test helper; the cloud install then runs `railwatch:doctor`. A
prompted/stdin/environment token goes into `.env` only when Git confirms that
file is ignored; token values are never printed. Configuration lives only in
that initializer; every option also has a `RAILWATCH_*` environment variable.
An embedded install mirrors to Railwatch Cloud as well with a token and
`c.export_enabled = true`.

## Rake tasks

| Task | Does |
|---|---|
| `bin/rails railwatch:doctor` | ✓/✗ per check. Embedded: databases, migrations, writer process, last write, maintenance, dashboard access, export. Cloud: token, token storage, ingest URL, reachability. Both: middleware, engine mount, deploy, sample rates, ignored types, Kamal hook, browser client and whether an entrypoint calls it, profiler backend, test matchers. Exits non-zero on a missing database, pending migrations, broken export, a missing or tracked token, or an unreachable host. **Run this first when telemetry is missing.** |
| `bin/rails railwatch:authentication:configure` | Sets the embedded dashboard's HTTP Basic credentials for the current `RAILS_ENV`. |
| `bin/rails railwatch:export:status` | What the export queue holds and whether it can send. |
| `bin/rails railwatch:token` | Where to create a Railwatch Cloud ingest token for this app. |
| `bin/rails railwatch:mcp` | Paste-ready MCP client configuration for this app's Railwatch Cloud. |
| `bin/rails railwatch:deploy[ref,name,url]` | Records a deploy marker (in the embedded database, or on the cloud). Use as a release step when not deploying with Kamal. |
| `bin/rails 'railwatch:sourcemaps[public,true]'` | Uploads Vite source maps for the configured deploy, then deletes acknowledged files. Run after building and before publishing assets. Omit `true` to retain files. See [Source maps](docs/source-maps.md). |

## Facade

```ruby
Railwatch.report(error, handled: true, severity: :warning,
               context: {order_id: order.id}, fingerprint: ["billing", "stripe"],
               attachments: {"payload.json" => body})
Railwatch.attach("payload.json", data, exception: error)

Railwatch.context(tenant: org.slug, plan: org.plan)  # onto the parent record and every exception
Railwatch.user { |user| {id: user.id, name: user.name, email: user.email} }
Railwatch.fingerprint { |error, default| error.is_a?(Timeout::Error) ? ["timeout"] : default }

Railwatch.span("pdf.render", template: "invoice", pages: 12) { renderer.call }  # returns the block's value
Railwatch.instrument_outgoing(:get, url) { client.get(url) }                    # clients with no built-in patch
Faraday.new(url) { |f| f.use Railwatch::Faraday }                               # Net::HTTP needs nothing

Railwatch.ignore { ExpensiveSync.run }   # also Railwatch.pause / Railwatch.resume
Railwatch.sample(0.01)                   # re-decide this execution; Railwatch.dont_sample to drop it
Railwatch.keep!                          # keep this execution whatever the head decision was
Railwatch.flush                          # ship what's buffered now

Railwatch.redact_queries { |q| q[:sql] = q[:sql].gsub(/'[^']*'/, "'?'") }
Railwatch.reject_outgoing_requests { |r| r[:host] == "127.0.0.1" }
Railwatch.reject_cache_keys %w[session: rack::attack*]
Railwatch.before_ingest { |batch| batch.reject { |r| r[:t] == "log" } }
Railwatch.on_unrecoverable { |error| Rails.error.report(error, handled: true) }
```

`redact_*`: requests, queries, exceptions, cache_events, commands, mail,
outgoing_requests, logs. `reject_*`: queries, cache_events, mail,
notifications, broadcasts, outgoing_requests, enqueued_jobs, logs.

Per action, in a controller class body: `railwatch_sample 0.01, only: :index`,
`railwatch_never_sample only: :ping`.

## Specs

`require "railwatch/rspec"` in `spec/rails_helper.rb` (or `"railwatch/minitest"` in
`test/test_helper.rb`). Railwatch must be enabled in the test env: an embedded
install is, and needs `RAILS_ENV=test bin/rails db:prepare` once so its test
databases exist; a cloud install needs any non-blank `RAILWATCH_TOKEN`. Records
go to an in-memory transport, never over the wire. All matchers are block
matchers.

```ruby
expect { get "/widgets" }.to have_railwatch_queries(at_most: 6)   # or exactly:/at_least:
expect { get "/widgets" }.not_to have_railwatch_n_plus_one
expect { Checkout.new(cart).total }.to record_railwatch_span("checkout.total")
expect { importer.run }.to record_railwatch_exception(ArgumentError)
expect { importer.run }.not_to record_railwatch_exceptions
expect { SyncCustomers.run }.to have_railwatch_outgoing_requests(at_most: 1)

records = railwatch_capture { get "/widgets" }   # everything the block produced
```

Minitest: `assert_railwatch_queries(at_most: 5) { }`,
`refute_railwatch_n_plus_one { }`, `assert_railwatch_span("name") { }`.

Use these to hold a hot path to a query budget in CI; failure messages list the
offending SQL. Seed enough rows that an N+1 actually crosses
`config.n_plus_one_threshold` (default 5), or the gate passes on code that would
melt in production.

## MCP

Railwatch Cloud (not embedded mode) is an MCP server at `<ingest host>/mcp`.
Generate a personal token at Settings → Profile → "API & MCP token", then:

```sh
claude mcp add railwatch --transport http https://railwatch.rebulk.com/mcp \
  --header "Authorization: Bearer rwp_your_token_here"
```

`bin/rails railwatch:mcp` prints this and the Claude Desktop, Cursor, VS Code, and
Zed equivalents for whichever platform the app points at. Call
`list_applications` first; then `list_issues`, `get_issue` (stack frames,
cause, locals, breadcrumbs), `get_route`, `search_requests`, `get_execution`,
`explain_query`, `get_profile`, `search_logs`, `search_telemetry`,
`release_health`, `recent_deploys`, `list_alerts`, and the `triage_issue` /
`slow_route` / `daily_summary` prompts. `update_issue` and `add_comment` write,
attributed to the token's user and your agent name. All durations are
milliseconds; these docs are served at `railwatch://docs/<name>`.

## Gotchas

- Sampling is decided **once per execution**; a sampled-out request ships nothing but its unhandled exception.
- If the app uses WebMock, re-prepend the patch after WebMock loads or outgoing
  requests are invisible in specs: `Net::HTTP.prepend(Railwatch::Patches::NetHttp)`.
- Profiling needs `vernier` or `stackprof` in the Gemfile; without one, `profile_sample` does nothing.
