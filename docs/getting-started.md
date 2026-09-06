# Getting started

Five minutes from `bundle add` to a request on the dashboard, on a
Rails 8 app. Everything below is the gem's own generator and rake tasks;
nothing else has to be wired by hand.

## 1. Add the gem

```sh
bundle add nightrail
```

The distribution name is `nightrail`. Its Ruby namespace and
explicit require paths remain `Nightrail::*` and `require "nightrail"`.

## 2. Run the installer

```sh
bin/rails generate nightrail:install
```

With the token already in hand, let the generator read it without placing the
secret in shell history or process arguments:

```sh
bin/rails generate nightrail:install \
  --prompt-token \
  --url=https://nightrail.rebulk.com \
  --kamal-secrets
```

- `--prompt-token` reads without echo. `--token-stdin` is available for a
  secret-manager pipe; an already exported `NIGHTRAIL_TOKEN` is also detected.
  The legacy `--token=` flag warns because command arguments can be visible in
  shell history and process listings.
- A token is written to `.env` only when Git confirms that `.env` is ignored.
  A tracked or non-ignored dotenv file is refused; use Rails credentials, a
  deployment secret manager, or add `.env` to `.gitignore first. Token values
  are never printed by the generator.
- `--url=` sets `NIGHTRAIL_INGEST_URL`, for a self-hosted platform. Leave
  it off to use the default, `https://nightrail.rebulk.com`.
- `--kamal-secrets` appends `NIGHTRAIL_TOKEN=$NIGHTRAIL_TOKEN` to
  `.kamal/secrets` and adds `NIGHTRAIL_TOKEN` under `env: secret:` in
  `config/deploy.yml`, which is the pair of edits Kamal needs to pass a
  secret through to the containers.

What the generator writes, in every case:

- `config/initializers/nightrail.rb`, with every option commented out at
  its default.
- `mount Nightrail::Engine, at: "/nightrail"` in `config/routes.rb` (the
  beacon endpoint the browser client posts to).
- `.kamal/hooks/post-deploy` — only if `config/deploy.yml` already
  exists.
- `app/frontend/lib/nightrail.ts` plus the `startNightrail()` call in your
  Inertia entrypoint — only if `app/frontend/` exists. If it can't find
  an entrypoint it prints the two lines to add.
- `require "nightrail/rspec"` in `spec/rails_helper.rb`, or
  `require "nightrail/minitest"` in `test/test_helper.rb`.

It finishes by running `nightrail:doctor` for you, so the install either
ends in a clean checklist or tells you what is still missing.

## 3. Where the token comes from

In Nightrail Cloud, create an application, then an environment inside it
(`production`, `staging`, one token each). The token is shown once, on
the page you land on right after creating the environment — copy it
then. If you lose it, rotate it from the environment's settings and
update `NIGHTRAIL_TOKEN`.

```sh
bin/rails nightrail:token   # prints the URL to create/copy a token
```

A token looks like `lt_` followed by 40 characters. The gem is
completely inert without one: `Nightrail.enabled?` is `config.enabled &&
token.present?`, so an app with no token installs no subscribers and
ships nothing.

## 4. Check the wiring

```sh
bin/rails nightrail:doctor
```

```
✓ token: lt_9Qv... (43 chars)
✓ ingest url: https://nightrail.rebulk.com
✓ ingest reachable: GET https://nightrail.rebulk.com/ingest/ping
✓ request middleware: Nightrail::Middleware::Request at position 0
✓ engine mounted: POST /nightrail/beacon -> nightrail/beacon#create
✓ deploy: 8f31c0a42e91 (from GIT_REV)
✓ sample rates: requests=1.0 jobs=1.0 commands=1.0 scheduled_tasks=1.0 exceptions=1.0
✓ ignored record types: none
```

It exits non-zero only when the token is missing or the ingest host is
unreachable; the rest of the checklist is informational. Every line and
what to do about a `✗` is in
[`troubleshooting.md`](troubleshooting.md).

`bin/rails nightrail:status` is the one-line version: it pings
`{ingest_url}/ingest/ping` and prints the ingest URL, deploy, and server.

## 5. Make one request

```sh
bin/rails server
curl http://localhost:3000/
```

Records are batched in-process and flushed every `flush_interval`
(2 seconds by default) or every 500 records, whichever comes first, so
the request shows up on the environment's **Requests** page a couple of
seconds after you make it — with its queries, cache reads, view renders,
and log lines already attached to it.

## Three optional lines

Each of these is worth adding, and none of them is required for requests,
jobs, queries, and exceptions to report.

**The browser client**, for Inertia visit timing, Core Web Vitals, and
JavaScript errors. The generator adds both lines to your entrypoint when
it finds one:

```ts
import { startNightrail } from "@/lib/nightrail"

startNightrail()
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
import { nightrailRootOptions } from "@/lib/nightrail"

createRoot(el, nightrailRootOptions()).render(<App {...props} />)
```

On React 18, whose roots take no error options, call
`reportError(error, { componentStack: info.componentStack })` from the
boundary's `componentDidCatch` instead. `startNightrail` also takes optional
`ignoreErrors`, `denyUrls`, and `tenant` settings; see
[`docs/configuration.md`](configuration.md) and
[`docs/replacing-sentry.md`](replacing-sentry.md).

**The Kamal post-deploy hook**, for deploy markers and the commit diff
between deploys. Generated at `.kamal/hooks/post-deploy` when
`config/deploy.yml` exists; see the Kamal section below.

**The test matchers**, which turn your suite into a performance gate:

```ruby
# spec/rails_helper.rb
require "nightrail/rspec"
```

```ruby
expect { get "/widgets" }.to have_nightrail_queries(at_most: 6)
expect { get "/widgets" }.not_to have_nightrail_n_plus_one
```

Full matcher list and a CI recipe: [`testing.md`](testing.md).

## What you'll see

Per environment, grouped the way the sidebar groups them:

**Activity** — Overview (throughput, p95, error rate, slowest routes,
newest issues, deploy markers), Requests (routes table and per-request
waterfall of every child record), Jobs, Scheduled tasks, Commands,
Exceptions, Queries (slow list and N+1 list with the app line that
issued them), Spans, Profiles, Transactions, View renders, Cache, Mail,
Notifications, Broadcasts, Outgoing requests, Storage, Logs,
Deprecations.

**Monitoring** — Visits (Inertia page-visit timing and web vitals),
Users, Tenants, Deploys, Releases (crash-free session and user rates),
Processes (Puma pool, Active Record pool, Solid Queue backlog), Alerts.

**Settings** — Thresholds, Usage. Issues and alert rules live one level
up, on the account.

## Deploying

### Kamal

Two edits, both of which `--kamal-secrets` makes for you:

```sh
# .kamal/secrets
NIGHTRAIL_TOKEN=$NIGHTRAIL_TOKEN
```

```yaml
# config/deploy.yml
env:
  secret:
    - NIGHTRAIL_TOKEN
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
should be reporting). It exits immediately when `NIGHTRAIL_TOKEN` isn't
set and never fails a deploy — every network call ends in `|| true`.

Set the optional `NIGHTRAIL_DEPLOY_URL` to link the deploy marker at a CI
run or a release page.

### Docker, Heroku, Render

Environment variables only:

```sh
NIGHTRAIL_TOKEN=lt_...
NIGHTRAIL_INGEST_URL=https://nightrail.rebulk.com   # only when self-hosting
NIGHTRAIL_DEPLOY=<release identifier>
```

`NIGHTRAIL_DEPLOY` is the explicit override. Without it, `config.deploy` checks,
in order: `KAMAL_VERSION`; `GIT_REV`, `GIT_SHA`, `SOURCE_VERSION`,
`HEROKU_SLUG_COMMIT`, `RENDER_GIT_COMMIT`, the tag from `FLY_IMAGE_REF`,
`VERCEL_GIT_COMMIT_SHA`, `CI_COMMIT_SHA`, and `GITHUB_SHA`; a Capistrano
`REVISION` file; then `.git/HEAD` through loose or packed refs. It never runs
Git during boot. Full 40-character SHAs are shortened to 12 characters. Set
`NIGHTRAIL_DETECT_DEPLOY=false` to disable inferred sources while retaining
`NIGHTRAIL_DEPLOY` and `KAMAL_VERSION`.

### No Kamal

Run the deploy task as a release or post-deploy step, so charts still
get deploy markers:

```sh
bin/rails "nightrail:deploy[$GIT_SHA,v42,https://ci.example.com/runs/42]"
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
  platform install.
- [`troubleshooting.md`](troubleshooting.md) — every `nightrail:doctor`
  line and what a failure means.
- [`faq.md`](faq.md) — overhead, retention, PII, unreachable platform.
- [`ai-and-mcp.md`](ai-and-mcp.md) — asking an AI assistant what broke.
