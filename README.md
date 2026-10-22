# Railwatch

First-class monitoring for Rails. One gem instruments requests, jobs,
scheduled tasks, commands, queries, exceptions, cache, mail, broadcasts,
outgoing HTTP, storage, views, and logs, and links them into one trace
per execution, for about half a millisecond per request plus tens of
microseconds per query, with zero writes to your database.

The gem is the agent. It sends what it records over HTTPS to a
Railwatch server, which stores it, groups exceptions into issues, sends
alerts, and serves the dashboard and an MCP server:

- **Railwatch Cloud** at <https://railwatch.rebulk.com>, the default.
- **Self-hosted [railwatch-rs](https://github.com/Rebulk/railwatch-rs)**,
  one static binary for many apps ([Self-hosting](docs/self-hosting.md)).
- **Embedded**: the [`railwatch-server`](https://github.com/Rebulk/railwatch-server)
  gem runs that server next to Puma for one app and serves the dashboard
  at `/railwatch`, with nothing else to run.

## Install

```sh
bundle add railwatch                                # 1. add the public gem
bin/rails generate railwatch:install --prompt-token # 2. hidden token input plus app wiring
bin/rails railwatch:doctor                          # check every piece is wired up after restart
```

For a self-hosted server, add `--url=https://telemetry.example.com`.
The generator's flags, getting a token, and deploying with Kamal,
Docker, Heroku, or Render are covered in
[Getting started](docs/getting-started.md). For an unreleased revision,
use the Git source instead:

```ruby
gem "railwatch", github: "Rebulk/railwatch"
```

### Embedded

To keep everything inside the app, add `railwatch-server` next to this
gem:

```ruby
# Gemfile
gem "railwatch"
gem "railwatch-server"
```

```ruby
# config/puma.rb
plugin :railwatch_server
```

It provisions its data under `storage/railwatch/<env>` on first boot and
points this gem at it, so there is no token to manage. The dashboard at
`/railwatch` is open in development and answers 401 elsewhere until you
give it a password with
`RAILS_ENV=production bin/rails railwatch:authentication:configure`, or
put it behind your own admin authentication
([Configuration](docs/configuration.md#dashboard-gate-railwatch-server)).
Everything else is in the
[railwatch-server README](https://github.com/Rebulk/railwatch-server#readme).

Railwatch 0.x kept embedded telemetry in two SQLite databases written by
`plugin :railwatch`. 1.0 removes that mode; see
[Coming from 0.x embedded mode](docs/getting-started.md#coming-from-0x-embedded-mode).

## What you get

- Requests, jobs, scheduled tasks, commands, queries, exceptions, and
  logs, linked into one trace per execution
  ([Record types](docs/records.md)).
- Sampling decided once per execution, plus tail sampling that keeps a
  sampled-out request that turns out slow or raises
  ([Configuration](docs/configuration.md)).
- An optional stack profiler through `vernier` or `stackprof`, off by
  default ([Configuration](docs/configuration.md)).
- LLM calls made through RubyLLM: tokens, cost, cut-off answers, tool
  calls and workflows, each tied to the request or job that made it
  ([Record types](docs/records.md#llm_call)).
- A browser client for Inertia apps: page-visit timing, Core Web Vitals,
  and browser errors ([Getting started](docs/getting-started.md)).
- RSpec and Minitest matchers that turn a query budget into a CI gate
  ([Testing](docs/testing.md)).
- An MCP server on the Railwatch server, so Claude Code, Cursor, VS Code,
  or Zed can read your production data
  ([AI assistants and MCP](docs/ai-and-mcp.md)).

Configuration lives in `config/initializers/railwatch.rb`; most options
also have a `RAILWATCH_*` environment variable.

```ruby
Railwatch.configure do |c|
  c.sample = { requests: 0.1, jobs: 1.0 }
  c.user { |u| { id: u.id, name: u.name, email: u.email } }
end
```

The same instrumentation runs in your test suite, so a spec can hold a
hot path to a query budget:

```ruby
expect { get "/widgets" }.to have_railwatch_queries(at_most: 6)
expect { get "/widgets" }.not_to have_railwatch_n_plus_one
```

## Documentation

- [Getting started](docs/getting-started.md) — the install and its token,
  embedded with railwatch-server, moving from 0.x embedded mode, the three
  optional lines, and deploying with Kamal, Docker, Heroku, Render, or none
  of them.
- [Configuration](docs/configuration.md) — every option and `RAILWATCH_*`
  variable, field by field.
- [Record types](docs/records.md) — every record Railwatch ships and every
  attribute on it, sourced from the code that builds it.
- [Testing](docs/testing.md) — the RSpec and Minitest matchers, and a CI
  performance gate.
- [AI assistants and MCP](docs/ai-and-mcp.md) — connecting Claude Code,
  Cursor, VS Code, or Zed to your production data.
- [Replacing Sentry](docs/replacing-sentry.md) — a step-by-step migration,
  option by option and call site by call site.
- [Coming from Laravel Nightwatch](docs/replacing-nightwatch.md) — the
  record-type mapping and the sampling model, for Laravel people.
- [Self-hosting](docs/self-hosting.md) — pointing the gem at your own
  railwatch-rs server.
- [Troubleshooting](docs/troubleshooting.md) — every failure mode, paired
  with the `railwatch:doctor` line it shows up as.
- [FAQ](docs/faq.md) — overhead numbers, retention, PII posture, SQLite.
- [Security](docs/security.md) — transport, capture defaults, the browser
  beacon, and application responsibilities.

AI coding agents working on an app that uses Railwatch: [`llms.txt`](llms.txt)
and [`AGENTS.md`](AGENTS.md).

## Replacing Sentry

Railwatch subscribes to `Rails.error` on install, so existing
`Rails.error.report` and `Rails.error.handle` calls are captured with no
code changes. Each exception is linked to the request, job, or command
it happened inside. The option-by-option mapping and the
supported-workload matrix live in
[Replacing Sentry](docs/replacing-sentry.md).

## Development

```sh
bundle install
bundle exec rspec
```
