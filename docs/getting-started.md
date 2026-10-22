# Getting started

Two commands on a Rails 8 app, a token, and the app reports to
Railwatch. Everything below is the gem's own generator and rake tasks;
nothing else has to be wired by hand.

The `railwatch` gem is the agent: it instruments the app and sends what
it records over HTTPS to a Railwatch server. The server is one of:

- **Railwatch Cloud** at <https://railwatch.rebulk.com>, the default.
- **Your own [railwatch-rs](https://github.com/Rebulk/railwatch-rs)**,
  one static binary that serves many apps
  ([Self-hosting](self-hosting.md)).
- **The [`railwatch-server`](https://github.com/Rebulk/railwatch-server)
  gem**, which runs railwatch-rs next to Puma for this one app and serves
  the dashboard at `/railwatch` ([below](#embedded-railwatch-server)).

## Install

```sh
bundle add railwatch
bin/rails generate railwatch:install
```

The gem, its Ruby namespace, and its require path share one name:
`railwatch`, `Railwatch::*`, `require "railwatch"`.

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
- A token is written to `.env` only when Git confirms that `.env` is ignored.
  A tracked or non-ignored dotenv file is refused; use Rails credentials, a
  deployment secret manager, or add `.env` to `.gitignore` first. Token values
  are never printed by the generator.
- `--url=` sets `RAILWATCH_INGEST_URL`, for a self-hosted server. Leave
  it off to use the default, `https://railwatch.rebulk.com`.
- `--kamal-secrets` appends `RAILWATCH_TOKEN=$RAILWATCH_TOKEN` to
  `.kamal/secrets` and adds `RAILWATCH_TOKEN` under `env: secret:` in
  `config/deploy.yml`, which is the pair of edits Kamal needs to pass a
  secret through to the containers.
- `--no-doctor` skips the `railwatch:doctor` run at the end.

### What the generator writes

- `config/initializers/railwatch.rb`, with every option commented out at
  its default.
- `mount Railwatch::Engine, at: "/railwatch"` in `config/routes.rb`: the
  beacon endpoint the browser client posts to (`POST /railwatch/beacon`).
- `.kamal/hooks/post-deploy` — only if `config/deploy.yml` already
  exists.
- `app/frontend/lib/railwatch.ts` plus the `startRailwatch()` call in your
  Inertia entrypoint — only if `app/frontend/` exists. If it can't find
  an entrypoint it prints the two lines to add.
- `require "railwatch/rspec"` in `spec/rails_helper.rb`, or
  `require "railwatch/minitest"` in `test/test_helper.rb`.

It finishes by running `railwatch:doctor`, so the install either ends in
a clean checklist or tells you what is still missing.

### Where the token comes from

In Railwatch Cloud, create an application, then an environment inside it
(`production`, `staging`, one token each). The token is shown once, on
the page you land on right after creating the environment — copy it
then. If you lose it, rotate it from the environment's settings and
update `RAILWATCH_TOKEN`. A self-hosted railwatch-rs creates tokens the
same way (or with `railwatch env create`; see its docs).

```sh
bin/rails railwatch:token   # prints the URL to create/copy a token
```

A token looks like `rw_` followed by 40 characters. The gem is inert
without one: `Railwatch.enabled?` is `config.enabled && token.present?`,
so an app with no token installs no subscribers and ships nothing.

### Check the wiring

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
the server answer 401 and that line is `✗` as well. Every line and what
to do about a `✗` is in [`troubleshooting.md`](troubleshooting.md).

`bin/rails railwatch:status` is the one-line version: it pings
`{ingest_url}/ingest/ping` and prints the ingest URL, deploy, and server.

## Embedded: railwatch-server

To keep telemetry inside the app instead, add the
[`railwatch-server`](https://github.com/Rebulk/railwatch-server) gem
next to this one. It bundles the railwatch-rs binary for your platform,
runs it as its own process beside Puma, and points this agent at it:

```ruby
# Gemfile
gem "railwatch"
gem "railwatch-server"
```

```ruby
# config/puma.rb
plugin :railwatch_server
```

On first boot it provisions `storage/railwatch/<env>` and sets the
agent's token and ingest URL itself, so no `RAILWATCH_TOKEN` is needed.
When `RAILWATCH_TOKEN` is set, it leaves the agent alone and only serves
the dashboard. The dashboard at `/railwatch` is behind this gem's gate
settings: HTTP Basic, on and closed (401) until credentials exist, except
in development when none are configured:

```sh
RAILS_ENV=production bin/rails railwatch:authentication:configure
```

To use your own admin authentication instead, turn Basic off and name a
base controller ([Configuration](configuration.md#dashboard-gate-railwatch-server)).
Everything else about it (ports, data directory, email, backups) is in
the [railwatch-server README](https://github.com/Rebulk/railwatch-server#readme).

### Coming from 0.x embedded mode

Railwatch 0.x could keep telemetry in two SQLite databases of the app's
own, written by a Puma writer process, with the dashboard served from the
gem. 1.0 removes that mode. To move:

1. Remove `c.transport = :local` (or `RAILWATCH_TRANSPORT=local`) from
   the initializer and environment.
2. Remove `plugin :railwatch` from `config/puma.rb`. Puma refuses to boot
   with a plugin it cannot find.
3. Remove the `railwatch` and `railwatch_telemetry` entries from
   `config/database.yml`.
4. Add `railwatch-server` as above, or point the app at Railwatch Cloud
   or a self-hosted railwatch-rs.

The old files (`storage/<env>_railwatch.sqlite3`,
`storage/<env>_railwatch_telemetry.sqlite3`) are not migrated, and
railwatch-rs has no import for them: its `railwatch import-rails` reads a
Railwatch Cloud (Rails) install, not these files. History starts again
in the new server. Delete the files once you no longer want them.

## Make one request

```sh
bin/rails server
curl http://localhost:3000/
```

Records are batched in-process and flushed every `flush_interval`
(2 seconds by default) or every 500 records, whichever comes first, so
the request shows up on the **Requests** page (the environment in
Railwatch Cloud or your own server, or `/railwatch` with
railwatch-server) a couple of seconds after you make it —
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

With railwatch-server, the server's data lives under
`storage/railwatch/<env>`, which has to be on a volume that survives
deploys (the Rails 8 Kamal template mounts `storage/`); its README covers
deploys and two containers sharing a volume. The token steps below are
for Railwatch Cloud or a self-hosted server.

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
- [`self-hosting.md`](self-hosting.md) — pointing the gem at your own
  railwatch-rs server.
- [`troubleshooting.md`](troubleshooting.md) — every `railwatch:doctor`
  line and what a failure means.
- [`faq.md`](faq.md) — overhead, retention, PII, unreachable platform.
- [`ai-and-mcp.md`](ai-and-mcp.md) — asking an AI assistant what broke.
