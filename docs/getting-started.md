# Getting started

Two commands on a Rails 8 app, then a dashboard at `/railwatch`.
Everything below is the gem's own generator and rake tasks; nothing else
has to be wired by hand.

## Install

```sh
bundle add railwatch
bin/rails generate railwatch:install
```

The gem, its Ruby namespace, and its require path share one name:
`railwatch`, `Railwatch::*`, `require "railwatch"`.

With no flags the install is [embedded](embedded.md): telemetry stays in
two SQLite databases the app owns, Puma forks one writer process for
them (`plugin :railwatch` in `config/puma.rb`), and the dashboard is
served from the app. No token, no cloud, no job worker. The generator
creates and migrates both databases before it returns. On a PostgreSQL
or MySQL app without the `sqlite3` gem it adds the gem instead; run
`bundle install` and `bin/rails db:prepare` to finish.

Restart the app and open `/railwatch`. In development it is open; every
other environment answers 401 until you give it a password:

```sh
RAILS_ENV=production bin/rails railwatch:authentication:configure
```

[Embedded mode](embedded.md#authentication) covers using your own
admin authentication instead.

### What the generator writes

In every mode:

- `config/initializers/railwatch.rb`, with every option commented out at
  its default (embedded: `c.transport = :local`).
- `mount Railwatch::Engine, at: "/railwatch"` in `config/routes.rb`: the
  embedded dashboard and the beacon endpoint the browser client posts to.
- `.kamal/hooks/post-deploy` — only if `config/deploy.yml` already
  exists.
- `app/frontend/lib/railwatch.ts` plus the `startRailwatch()` call in your
  Inertia entrypoint — only if `app/frontend/` exists. If it can't find
  an entrypoint it prints the two lines to add.
- `require "railwatch/rspec"` in `spec/rails_helper.rb`, or
  `require "railwatch/minitest"` in `test/test_helper.rb`.

Embedded adds the two databases to `config/database.yml` and the Puma
plugin line; see [Embedded mode](embedded.md#your-applications-own-database).

### Check the wiring

```sh
bin/rails railwatch:doctor
```

With the app running, the embedded checklist starts like this:

```
✓ transport: local (telemetry stays in this app; dashboard at the engine mount)
✓ railwatch database: storage/development_railwatch.sqlite3
✓ railwatch_telemetry database: storage/development_railwatch_telemetry.sqlite3
✓ railwatch_telemetry migrations: up to date
✓ railwatch migrations: up to date
✓ telemetry disk: auto_vacuum=incremental; the nightly prune returns freed pages
✓ writer process: listening at /app/tmp/sockets/railwatch-writer.sock
✓ last write: 12 seconds ago
✓ dashboard access: open in development. Production stays closed until you run `RAILS_ENV=production bin/rails railwatch:authentication:configure`
✓ request middleware: Railwatch::Middleware::Request at position 0
✓ engine mounted: POST /railwatch/beacon -> railwatch/beacon#create
```

With the app stopped, `writer process` and `maintenance` are `✗`, and say
so. Every line and what to do about a `✗` is in
[`troubleshooting.md`](troubleshooting.md).

### Adding Railwatch Cloud

Railwatch Cloud delivers alerts to Slack, email, webhooks or Linear
(embedded mode only records them), serves the [MCP server](ai-and-mcp.md)
to your AI assistant, and puts many apps and servers in one place. An
embedded install can mirror every record to it and keep `/railwatch`:
set a token ([below](#where-the-token-comes-from)) and
`c.export_enabled = true`. See
[Embedded mode](embedded.md#three-ways-to-run-it).

## Railwatch Cloud instead

To send telemetry only to Railwatch Cloud, with no local databases, run
the same generator with `--cloud`:

```sh
bundle add railwatch
bin/rails generate railwatch:install --cloud
```

With the token already in hand, let the generator read it without placing the
secret in shell history or process arguments:

```sh
bin/rails generate railwatch:install \
  --prompt-token \
  --url=https://railwatch.rebulk.com \
  --kamal-secrets
```

- `--prompt-token` reads without echo. `--token-stdin` is available for a
  secret-manager pipe; an already exported `RAILWATCH_TOKEN` is also detected.
- Any of `--prompt-token`, `--token-stdin`, `--url=` and `--kamal-secrets`
  means the cloud, so none of them needs `--cloud` as well. An exported
  `RAILWATCH_TOKEN` on its own does not: without one of these flags the
  install is embedded.
- A token is written to `.env` only when Git confirms that `.env` is ignored.
  A tracked or non-ignored dotenv file is refused; use Rails credentials, a
  deployment secret manager, or add `.env` to `.gitignore` first. Token values
  are never printed by the generator.
- `--url=` sets `RAILWATCH_INGEST_URL`, for a self-hosted platform. Leave
  it off to use the default, `https://railwatch.rebulk.com`.
- `--kamal-secrets` appends `RAILWATCH_TOKEN=$RAILWATCH_TOKEN` to
  `.kamal/secrets` and adds `RAILWATCH_TOKEN` under `env: secret:` in
  `config/deploy.yml`, which is the pair of edits Kamal needs to pass a
  secret through to the containers.

It writes the same files as the embedded install
([above](#what-the-generator-writes)) minus the databases and the Puma
plugin, and finishes by running `railwatch:doctor`, so the install either
ends in a clean checklist or tells you what is still missing.

### Where the token comes from

In Railwatch Cloud, create an application, then an environment inside it
(`production`, `staging`, one token each). The token is shown once, on
the page you land on right after creating the environment — copy it
then. If you lose it, rotate it from the environment's settings and
update `RAILWATCH_TOKEN`.

```sh
bin/rails railwatch:token   # prints the URL to create/copy a token
```

A token looks like `rw_` followed by 40 characters. A cloud install is
inert without one: with `transport = :http`, `Railwatch.enabled?` is
`config.enabled && token.present?`, so an app with no token installs no
subscribers and ships nothing.

### Check the cloud wiring

```sh
bin/rails railwatch:doctor
```

```
✓ token: rw_9Qv... (43 chars)
✓ token storage: no tracked plaintext Railwatch token found
✓ ingest url: https://railwatch.rebulk.com
✓ ingest transport security: HTTPS with certificate verification
✓ ingest reachable: GET https://railwatch.rebulk.com/ingest/ping
✓ request middleware: Railwatch::Middleware::Request at position 0
✓ engine mounted: POST /railwatch/beacon -> railwatch/beacon#create
✓ deploy: 8f31c0a42e91 (from GIT_REV)
✓ sample rates: requests=1.0 jobs=1.0 commands=1.0 scheduled_tasks=1.0 channels=1.0 exceptions=1.0
✓ ignored record types: none
```

It exits non-zero on three lines: `token` (missing), `token storage`
(a plaintext token in a tracked file), and `ingest reachable`. The rest
of the checklist is informational. Run it after the token is in place:
`ingest reachable` sends the token, so a missing or wrong token makes
the platform answer 401 and that line is `✗` as well.

`bin/rails railwatch:status` is the one-line version: it pings
`{ingest_url}/ingest/ping` and prints the ingest URL, deploy, and server.

## Make one request

```sh
bin/rails server
curl http://localhost:3000/
```

Records are batched in-process and flushed every `flush_interval`
(2 seconds by default) or every 500 records, whichever comes first, so
the request shows up on the **Requests** page (`/railwatch`, or the
environment in Railwatch Cloud) a couple of seconds after you make it —
with its queries, cache reads, view renders, and log lines already
attached to it.

## Three optional lines

Each of these is worth adding, and none of them is required for requests,
jobs, queries, and exceptions to report.

**The browser client**, for Inertia visit timing, Core Web Vitals, and
JavaScript errors. The generator adds both lines to your entrypoint when
it finds one:

```ts
import { startRailwatch } from "@/lib/railwatch"

startRailwatch()
```

Errors ride the same beacon as visit timing — uncaught errors, unhandled
promise rejections, and Inertia's own failed-request events (`exception`
and `invalid` on Inertia 2, `networkError` and `httpException` on 3) —
and land as ordinary issues next to your Ruby ones.

If you have React error boundaries, add one more line where the root is
created. React does not report a boundary-caught error to `window.onerror`
outside a development build, so this is the only thing that gets a caught
render error out of production:

```tsx
import { createRoot } from "react-dom/client"
import { railwatchRootOptions } from "@/lib/railwatch"

createRoot(el, railwatchRootOptions()).render(<App {...props} />)
```

On React 18, whose roots take no error options, call
`reportError(error, { componentStack: info.componentStack })` from the
boundary's `componentDidCatch` instead. `startRailwatch` also takes optional
`ignoreErrors`, `denyUrls`, and `tenant` settings; see
[`docs/configuration.md`](configuration.md) and
[`docs/replacing-sentry.md`](replacing-sentry.md).

**The Kamal post-deploy hook**, for deploy markers and the commit diff
between deploys. Generated at `.kamal/hooks/post-deploy` when
`config/deploy.yml` exists; see the Kamal section below.

**The test matchers**, which turn your suite into a performance gate:

```ruby
# spec/rails_helper.rb
require "railwatch/rspec"
```

```ruby
expect { get "/widgets" }.to have_railwatch_queries(at_most: 6)
expect { get "/widgets" }.not_to have_railwatch_n_plus_one
```

Full matcher list and a CI recipe: [`testing.md`](testing.md).

## What you'll see

Per environment, grouped the way the sidebar groups them:

**Activity** — Overview (throughput, p95, error rate, slowest routes,
newest issues, deploy markers), Requests (routes table and per-request
waterfall of every child record), Jobs, Scheduled tasks, Commands,
Exceptions, Queries (slow list and N+1 list with the app line that
issued them), Spans, Profiles, Transactions, View renders, Cache, Mail,
Notifications, Broadcasts, Outgoing requests, LLM (RubyLLM calls with
tokens, cost, cut-offs and tool calls), Storage, Logs, Deprecations.

**Monitoring** — Visits (Inertia page-visit timing and web vitals),
Users, Tenants, Deploys, Releases (crash-free session and user rates),
Processes (Puma pool, Active Record pool, Solid Queue backlog), Alerts.

**Settings** — Thresholds, Usage. Issues and alert rules live one level
up, on the account.

## Deploying

An embedded install deploys like the rest of the app: the two databases
are files under `storage/`, which the Rails 8 Kamal template already
mounts as a volume, and the Rails 8 Docker entrypoint's
`bin/rails db:prepare` migrates them. Give the
dashboard a password first ([Install](#install)). For deploy markers
from the Kamal hook, set `RAILWATCH_TRANSPORT=local` in the deployer's
environment ([Embedded mode](embedded.md#deploys)). The token steps
below are for a cloud install or export.

### Kamal

Two edits, both of which `--kamal-secrets` makes for you:

```sh
# .kamal/secrets
RAILWATCH_TOKEN=$RAILWATCH_TOKEN
```

```yaml
# config/deploy.yml
env:
  secret:
    - RAILWATCH_TOKEN
```

`config.deploy` picks up `KAMAL_VERSION` on its own, so every record is
stamped with the version that shipped it without any further
configuration.

The generated `.kamal/hooks/post-deploy` adds the deploy marker itself.
It runs on the deployer machine — which, unlike a container, has the git
history and Kamal's `KAMAL_*` variables — and POSTs twice: the deploy
(`{deploy, ref, name, url, server, timestamp, performer, destination,
service, commits}`, with up to 50 commits, which is what gives the
Deploys page a diff of what actually shipped) and the Kamal host list
(`{version, hosts, roles, ...}`, so the platform knows which servers
should be reporting). It exits immediately when `RAILWATCH_TOKEN` isn't
set and never fails a deploy — every network call ends in `|| true`.

Set the optional `RAILWATCH_DEPLOY_URL` to link the deploy marker at a CI
run or a release page.

### Docker, Heroku, Render

Environment variables only:

```sh
RAILWATCH_TOKEN=rw_...
RAILWATCH_INGEST_URL=https://railwatch.rebulk.com   # only when self-hosting
RAILWATCH_DEPLOY=<release identifier>
```

`RAILWATCH_DEPLOY` is the explicit override. Without it, `config.deploy` checks,
in order: `KAMAL_VERSION`; `GIT_REV`, `GIT_SHA`, `SOURCE_VERSION`,
`HEROKU_SLUG_COMMIT`, `RENDER_GIT_COMMIT`, the tag from `FLY_IMAGE_REF`,
`VERCEL_GIT_COMMIT_SHA`, `CI_COMMIT_SHA`, and `GITHUB_SHA`; a Capistrano
`REVISION` file; then `.git/HEAD` through loose or packed refs. It never runs
Git during boot. Full 40-character SHAs are shortened to 12 characters. Set
`RAILWATCH_DETECT_DEPLOY=false` to disable inferred sources while retaining
`RAILWATCH_DEPLOY` and `KAMAL_VERSION`.

### No Kamal

Run the deploy task as a release or post-deploy step, so charts still
get deploy markers:

```sh
bin/rails "railwatch:deploy[$GIT_SHA,v42,https://ci.example.com/runs/42]"
```

All three arguments are optional: `ref` defaults to `git rev-parse HEAD`,
`name` and `url` are labels for the marker. The task aborts if
`config.deploy` is unset. Run inside a container built from a repo with
no `.git`, the commit list comes back empty and the marker ships without
one — the deploy is still recorded.

## Next

- [`configuration.md`](configuration.md) — every option, env var, and
  default.
- [`records.md`](records.md) — every record type, field by field.
- [`testing.md`](testing.md) — matchers and the CI performance gate.
- [`replacing-sentry.md`](replacing-sentry.md) — migrating off
  `sentry-rails`.
- [`replacing-nightwatch.md`](replacing-nightwatch.md) — for people
  coming from Laravel.
- [`embedded.md`](embedded.md) — authentication, the writer process,
  maintenance, disk, and export to the cloud.
- [`self-hosting.md`](self-hosting.md) — pointing the gem at your own
  platform install.
- [`troubleshooting.md`](troubleshooting.md) — every `railwatch:doctor`
  line and what a failure means.
- [`faq.md`](faq.md) — overhead, retention, PII, unreachable platform.
- [`ai-and-mcp.md`](ai-and-mcp.md) — asking an AI assistant what broke
  (Railwatch Cloud).
