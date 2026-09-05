# Lantern

First-class monitoring for Rails. One gem instruments requests, jobs,
scheduled tasks, commands, queries, exceptions, cache, mail, broadcasts,
outgoing HTTP, storage, views, and logs, links them into one trace per
execution, and ships them to Lantern Cloud with under a millisecond of
overhead per request and zero writes to your database.

## Install

```sh
bundle add lantern                          # 1. add the gem
bin/rails generate lantern:install --prompt-token  # 2. hidden token input plus app wiring
bin/rails lantern:doctor                    # 3. check every piece is wired up after restart
```

The generator writes `config/initializers/lantern.rb`, mounts the beacon
engine, and — where the app already has them — adds a Kamal `post-deploy`
hook, the Inertia browser client with its `startLantern()` call, and
`require "lantern/rspec"` in `spec/rails_helper.rb`. `lantern:doctor` prints
a ✓/✗ checklist of all of it and exits non-zero if the token is missing or
the ingest host is unreachable.

Pass `--prompt-token` (and `--url=` when self-hosting) to read the token
without echo or process-argument exposure. The generator writes it to `.env`
only when Git confirms that file is ignored; otherwise it points you to Rails
credentials or your deployment secret manager without printing the value. Add
`--kamal-secrets` to wire `LANTERN_TOKEN` through `.kamal/secrets` and
`config/deploy.yml`. It finishes by running `lantern:doctor` for you.
`bin/rails lantern:token` says where to get a token; `bin/rails lantern:mcp`
prints ready-to-paste MCP client configuration.

## Documentation

- [Getting started](docs/getting-started.md) — five-minute install for a
  Rails 8 app, the three optional lines, and deploying with Kamal, Docker,
  Heroku, Render, or none of them.
- [Configuration](docs/configuration.md) — every option and `LANTERN_*`
  variable, field by field.
- [Record types](docs/records.md) — every record Lantern ships and every
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
  Lantern Cloud.
- [Troubleshooting](docs/troubleshooting.md) — every failure mode, paired
  with the `lantern:doctor` line it shows up as.
- [FAQ](docs/faq.md) — overhead numbers, retention, PII posture, SQLite.

AI coding agents working on an app that uses Lantern: [`llms.txt`](llms.txt)
and [`AGENTS.md`](AGENTS.md).

Configuration lives in `config/initializers/lantern.rb`; every option has
a `LANTERN_*` environment variable. Sampling is decided once per execution:
a sampled-in request ships its whole tree, a sampled-out one ships nothing
except unhandled exceptions.

```ruby
Lantern.configure do |c|
  c.sample = { requests: 0.1, jobs: 1.0 }
  c.user { |u| { id: u.id, name: u.name, email: u.email } }
end

class ReportsController < ApplicationController
  lantern_sample 0.01, only: :index
end

Lantern.ignore { ExpensiveSync.run }
Lantern.context(tenant: org.slug, plan: org.plan)
```

Time any block of your own code as a `span` on the surrounding request,
job, or command — the block's value is returned untouched:

```ruby
Lantern.span("pdf.render", template: "invoice", pages: 12) { renderer.call }
```

When a span isn't enough to say where the time went, Lantern can attach a
real stack profile to an execution. Add `gem "vernier"` (Ruby ≥ 3.2) or
`gem "stackprof"` to the Gemfile and set `c.profile_sample = 0.01` to
profile 1% of executions, or `c.profile_slow_ms = 500` alongside
`c.tail_sample_slow_ms` to profile the slow ones. The collapsed stacks
ship as their own `profile` record, gzipped, and the request or job it
belongs to is marked `profiled`. Off by default, and one Float comparison
per execution while it stays off.

Sampling can also be decided at the *end* of an execution instead of the
start: set `c.tail_sample_slow_ms = 500` (or call `Lantern.keep!`) and a
head-sampled-out request that turns out to be slow, or to have raised,
ships its whole tree anyway. Outgoing HTTP carries a W3C `traceparent`,
and an inbound one is adopted, so a trace spans services.

Inertia apps get real page-visit timing by calling `startLantern()` from the
generated `app/frontend/lib/lantern.ts`. Server-side rendering is timed
automatically wherever `inertia_rails` SSR is already enabled — no extra
configuration needed.

Outgoing HTTP made through Faraday is instrumented by adding
`Lantern::Faraday` to the connection's middleware stack (`Net::HTTP` is
already covered globally, with no setup); any other client can be wrapped
with `Lantern.instrument_outgoing`:

```ruby
Faraday.new(url) { |f| f.use Lantern::Faraday }
Lantern.instrument_outgoing(:get, url) { http_client.get(url) }
```

## Testing

The same instrumentation runs in your test suite, so a spec can hold a hot
path to a query budget and CI can fail the pull request that regresses it:

```ruby
expect { get "/widgets" }.to have_lantern_queries(at_most: 6)
expect { get "/widgets" }.not_to have_lantern_n_plus_one
```

Failures list the offending SQL. Set-up, every matcher (RSpec and Minitest),
and a CI performance-gate recipe are in [`docs/testing.md`](docs/testing.md).

---

Every attribute, the full public facade, sampling, redaction/rejection,
transport/buffering behavior, the overhead gate, and the Kamal deploy hook
are documented field-by-field in [`docs/configuration.md`](docs/configuration.md).
Every record type Lantern ships — `request`, `job_attempt`, `query`,
`exception`, and the rest — is documented field-by-field, sourced directly
from the code that builds it, in [`docs/records.md`](docs/records.md).

## Replacing Sentry

Lantern subscribes to `Rails.error` on install
(`Rails.error.subscribe`), so any existing `Rails.error.report` or
`Rails.error.handle` call — which is how Sentry's own Rails integration
is normally wired in — is captured with no code changes. An unhandled
exception bypasses the execution buffer: it is enqueued immediately and
wakes the in-memory reporter without doing network I/O on the application
thread. Delivery is still asynchronous and memory-only, so a hard kill,
OOM, or process exit after the shutdown deadline can lose it.

What differs from a dedicated error tracker: exceptions aren't reported in
isolation — each one is linked (`execution_id`/`trace_id`) to the request,
job, or command it happened inside, alongside every query, cache read,
outgoing request, and log line from that same execution. There's no
separate error-tracking SDK/config to maintain — `severity`, `handled`,
and `context` all come from the same `Lantern.configure` block and
`Lantern.context` calls used for everything else the gem instruments.

### Coming from Sentry

| Sentry | Lantern |
|---|---|
| `dsn:` | `LANTERN_TOKEN` (+ `LANTERN_INGEST_URL` for a self-hosted platform). |
| `environment:` | `config.environment` — defaults to `Rails.env`, set it only to report under a different name. |
| `release:` | `config.deploy` — `LANTERN_DEPLOY`, else `KAMAL_VERSION`, else `GIT_REV`. Stamped on every record. |
| `traces_sample_rate:` / `profiles_sample_rate:` | `config.sample`, a rate per execution kind (`requests`, `jobs`, `commands`, `scheduled_tasks`, `exceptions`), decided once per execution rather than per event. Per-route: `lantern_sample 0.01, only: :index`. |
| `excluded_exceptions:` | `config.ignored_exceptions` — same default list, plus every named ancestor is matched, not just the exact class. |
| `before_send:` / `before_send_transaction:` | `Lantern.before_ingest { \|batch\| ... }` for the whole outgoing batch; `Lantern.redact_queries`/`redact_logs`/... to scrub one record type in place; `Lantern.reject_queries`/`reject_logs`/... to drop records by predicate. |
| `fingerprint` / grouping rules | `Lantern.fingerprint { \|error, default\| ... }` globally, `def lantern_fingerprint` on your own error class, or `Lantern.report(error, fingerprint: [...])` per call. The literal `:default` splices in the parts Lantern would have hashed, like Sentry's `{{ default }}`. |
| `include_local_variables:` | `config.capture_exception_locals`. |
| `send_default_pii:` | Deliberately split: `config.capture_request_payload` for params, `config.capture_job_arguments` for job arguments, `config.capture_response_body_on_error` for what a failing upstream sent back, `config.redact_headers`/`redact_params` for what's scrubbed, and the `Lantern.user { ... }` block for who. There is no single "send everything" switch. |
| Breadcrumbs | Not a separate concept — every query, cache read, outgoing request, log line, and view render is already a first-class record linked to its execution by `execution_id`/`trace_id`. The execution *is* the breadcrumb trail, and it's queryable. |
| `Sentry.capture_message` | `Lantern.report(error, ...)` for an exception; plain `Rails.logger` for a message — log lines at or above `config.log_level` become `log` records automatically. |
| `Sentry.set_user` | `Lantern.user { ... }` (a resolver block, evaluated per execution). |
| `Sentry.set_tags` / `set_context` / `set_extras` | `Lantern.context(key: value)` — serialized onto the parent record and every exception. |
| `Sentry.with_child_span` | `Lantern.span("name") { ... }`. |
| `Sentry.add_attachment` | `Lantern.attach("payload.json", data)` — a String, `Pathname`, or IO, gzipped on the wire and capped at `config.max_attachment_bytes`. `exception:` files it against that error's issue, and `Lantern.report(error, attachments: { "payload.json" => data })` captures and attaches in one call. |
| `Sentry.capture_check_in` (cron monitoring) | Automatic: Solid Queue recurring tasks become `scheduled_task` records with `task_key`, `schedule`, and `drift`. Nothing to instrument. |
| `config.rails.report_rescued_exceptions` | `config.capture_rescued_exceptions` (on by default). |
| Rack `X-Request-Start` queue time | Automatic: `queue_time` on every `request` record. |
| `auto_session_tracking:` (release health) | Automatic: `session` records from the browser client and the request middleware, keyed on `config.deploy` as the release. `config.track_sessions` turns both off. |

These mappings cover the Rails-server migration path. Browser Replay,
native/mobile SDKs, some direct worker and scheduler entry points, and
Sentry's broader managed integration catalog are not equivalent today.
Use the supported-workload matrix in
[`docs/replacing-sentry.md`](docs/replacing-sentry.md) before removing
Sentry from an application that depends on those capabilities.

To report an exception manually (the `Rails.error.report`-equivalent):

```ruby
Lantern.report(error, handled: true, context: { order_id: order.id })
```

`severity` defaults to `:warning` when `handled: true`, `:error`
otherwise. See the `exception` section of
[`docs/records.md`](docs/records.md) for the full field list, and
[`docs/configuration.md`](docs/configuration.md) for redaction
(`Lantern.redact_exceptions`), `capture_exception_source`, and
`Lantern.on_unrecoverable` (Lantern watching its own internal failures).

## Development

```sh
bundle install
bundle exec rspec
```
