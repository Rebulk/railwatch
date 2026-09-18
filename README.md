# Railwatch

First-class monitoring for Rails. One gem instruments requests, jobs,
scheduled tasks, commands, queries, exceptions, cache, mail, broadcasts,
outgoing HTTP, storage, views, and logs, links them into one trace per
execution, and ships them to Railwatch Cloud for about half a millisecond
per request plus tens of microseconds per query, with zero writes to your
database.

## Install

```sh
bundle add railwatch            # 1. add the public gem
bin/rails generate railwatch:install --prompt-token  # 2. hidden token input plus app wiring
bin/rails railwatch:doctor                    # 3. check every piece is wired up after restart
```

Or keep everything inside your app, with the full dashboard at
`/railwatch` and no token ([Embedded mode](docs/embedded.md)):

```sh
bundle add railwatch
bin/rails generate railwatch:install --local
```

Getting the token, the generator's flags, and deploying with Kamal,
Docker, Heroku, or Render are covered in
[Getting started](docs/getting-started.md). For a self-hosted deployment
or an unreleased revision, use the Git source instead:

```ruby
gem "railwatch", github: "Rebulk/railwatch"
```

## What you get

- Requests, jobs, scheduled tasks, commands, queries, exceptions, and
  logs, linked into one trace per execution
  ([Record types](docs/records.md)).
- Sampling decided once per execution, plus tail sampling that keeps a
  sampled-out request that turns out slow or raises
  ([Configuration](docs/configuration.md)).
- An optional stack profiler through `vernier` or `stackprof`, off by
  default ([Configuration](docs/configuration.md)).
- A browser client for Inertia apps: page-visit timing, Core Web Vitals,
  and browser errors ([Getting started](docs/getting-started.md)).
- RSpec and Minitest matchers that turn a query budget into a CI gate
  ([Testing](docs/testing.md)).
- An MCP server so Claude Code, Cursor, VS Code, or Zed can read your
  production data ([AI assistants and MCP](docs/ai-and-mcp.md)).

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

- [Getting started](docs/getting-started.md) — five-minute install for a
  Rails 8 app, the three optional lines, and deploying with Kamal, Docker,
  Heroku, Render, or none of them.
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
- [Embedded mode](docs/embedded.md) — the whole dashboard inside your
  app, telemetry in your own SQLite files, no cloud.
- [Self-hosting](docs/self-hosting.md) — pointing the gem at your own
  Railwatch Cloud.
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
