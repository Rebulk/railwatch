# Lantern, for coding agents

About *using* the `lantern-observability` gem from a Rails application; copy
this into that application's repository. Index of everything else:
[`llms.txt`](llms.txt).

Lantern instruments a Rails app end to end and ships linked telemetry to
Lantern Cloud. Every request, job attempt, scheduled task run, and command is
an **execution**; every query, cache read, log line, outgoing HTTP call, view
render, exception, and span is a child of one, linked by
`execution_id`/`trace_id`. It never writes to the app's database.

## Install

```sh
bundle add lantern-observability
bin/rails generate lantern:install --token=lt_... --kamal-secrets
```

The generator writes `config/initializers/lantern.rb`, mounts `Lantern::Engine`
at `/lantern`, adds the Kamal `post-deploy` hook and the Inertia browser client
where the app has them, requires `lantern/rspec` (or `lantern/minitest`) in the
test helper, and then runs `lantern:doctor`. `--token=`/`--url=` go into `.env`
if the app uses dotenv, else are printed. Configuration lives only in that
initializer; every option also has a `LANTERN_*` environment variable.
The distribution name is `lantern-observability`, while the Ruby namespace and
explicit require paths remain `Lantern::*` and `lantern/...`.

## Rake tasks

| Task | Does |
|---|---|
| `bin/rails lantern:doctor` | ✓/✗ per check: token, ingest URL, reachability, middleware, engine mount, deploy marker, sample rates, ignored types, Kamal hook, browser client and whether an entrypoint calls it, profiler backend, test matchers. Exits non-zero if the token is missing or the host is unreachable. **Run this first when telemetry is missing.** |
| `bin/rails lantern:token` | Where to create an ingest token for this app's platform. |
| `bin/rails lantern:mcp` | Paste-ready MCP client configuration for this app's platform. |
| `bin/rails lantern:deploy[ref,name,url]` | Records a deploy marker. Use as a release step when not deploying with Kamal. |

## Facade

```ruby
Lantern.report(error, handled: true, severity: :warning,
               context: {order_id: order.id}, fingerprint: ["billing", "stripe"],
               attachments: {"payload.json" => body})
Lantern.attach("payload.json", data, exception: error)

Lantern.context(tenant: org.slug, plan: org.plan)  # onto the parent record and every exception
Lantern.user { |user| {id: user.id, name: user.name, email: user.email} }
Lantern.fingerprint { |error, default| error.is_a?(Timeout::Error) ? ["timeout"] : default }

Lantern.span("pdf.render", template: "invoice", pages: 12) { renderer.call }  # returns the block's value
Lantern.instrument_outgoing(:get, url) { client.get(url) }                    # clients with no built-in patch
Faraday.new(url) { |f| f.use Lantern::Faraday }                               # Net::HTTP needs nothing

Lantern.ignore { ExpensiveSync.run }   # also Lantern.pause / Lantern.resume
Lantern.sample(0.01)                   # re-decide this execution; Lantern.dont_sample to drop it
Lantern.keep!                          # keep this execution whatever the head decision was
Lantern.flush                          # ship what's buffered now

Lantern.redact_queries { |q| q[:sql] = q[:sql].gsub(/'[^']*'/, "'?'") }
Lantern.reject_outgoing_requests { |r| r[:host] == "127.0.0.1" }
Lantern.reject_cache_keys %w[session: rack::attack*]
Lantern.before_ingest { |batch| batch.reject { |r| r[:t] == "log" } }
Lantern.on_unrecoverable { |error| Rails.error.report(error, handled: true) }
```

`redact_*`: requests, queries, exceptions, cache_events, commands, mail,
outgoing_requests, logs. `reject_*`: queries, cache_events, mail,
notifications, broadcasts, outgoing_requests, enqueued_jobs, logs.

Per action, in a controller class body: `lantern_sample 0.01, only: :index`,
`lantern_never_sample only: :ping`.

## Specs

`require "lantern/rspec"` in `spec/rails_helper.rb` (or `"lantern/minitest"` in
`test/test_helper.rb`). Lantern must be enabled in the test env — set any
non-blank `LANTERN_TOKEN`; records go to an in-memory transport, never over the
wire. All matchers are block matchers.

```ruby
expect { get "/widgets" }.to have_lantern_queries(at_most: 6)   # or exactly:/at_least:
expect { get "/widgets" }.not_to have_lantern_n_plus_one
expect { Checkout.new(cart).total }.to record_lantern_span("checkout.total")
expect { importer.run }.to record_lantern_exception(ArgumentError)
expect { importer.run }.not_to record_lantern_exceptions
expect { SyncCustomers.run }.to have_lantern_outgoing_requests(at_most: 1)

records = lantern_capture { get "/widgets" }   # everything the block produced
```

Minitest: `assert_lantern_queries(at_most: 5) { }`,
`refute_lantern_n_plus_one { }`, `assert_lantern_span("name") { }`.

Use these to hold a hot path to a query budget in CI; failure messages list the
offending SQL. Seed enough rows that an N+1 actually crosses
`config.n_plus_one_threshold` (default 5), or the gate passes on code that would
melt in production.

## MCP

The platform is an MCP server at `<ingest host>/mcp`. Generate a personal
token at Settings → Profile → "API & MCP token", then:

```sh
claude mcp add lantern --transport http https://lantern.rebulk.com/mcp \
  --header "Authorization: Bearer lnt_your_token_here"
```

`bin/rails lantern:mcp` prints this and the Claude Desktop, Cursor, VS Code, and
Zed equivalents for whichever platform the app points at. Call
`list_applications` first; then `list_issues`, `get_issue`, `get_route`,
`search_requests`, `get_execution`, `explain_query`, `get_profile`,
`search_logs`, `release_health`, `recent_deploys`, `list_alerts`, and the
`triage_issue` / `slow_route` / `daily_summary` prompts. All durations are
milliseconds; these docs are served at `lantern://docs/<name>`.

## Gotchas

- Sampling is decided **once per execution**; a sampled-out request ships nothing but its unhandled exception.
- If the app uses WebMock, re-prepend the patch after WebMock loads or outgoing
  requests are invisible in specs: `Net::HTTP.prepend(Lantern::Patches::NetHttp)`.
- Profiling needs `vernier` or `stackprof` in the Gemfile; without one, `profile_sample` does nothing.
