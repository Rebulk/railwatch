# Getting started

Five minutes from `bundle add` to a request on the dashboard, on a
Rails 8 app. Everything below is the gem's own generator and rake tasks;
nothing else has to be wired by hand.

## 1. Add the gem

```sh
bundle add lantern
```

## 2. Run the installer

```sh
bin/rails generate lantern:install
```

With the token already in hand you can hand it to the generator instead
of editing files afterwards:

```sh
bin/rails generate lantern:install \
  --token=lt_... \
  --url=https://lantern.rebulk.com \
  --kamal-secrets
```

- `--token=` writes `LANTERN_TOKEN` to `.env` when the app already has
  one or bundles `dotenv`. When it doesn't, the generator prints exactly
  where to put the token instead of inventing a file for it.
- `--url=` sets `LANTERN_INGEST_URL`, for a self-hosted platform. Leave
  it off to use the default, `https://lantern.rebulk.com`.
- `--kamal-secrets` appends `LANTERN_TOKEN=$LANTERN_TOKEN` to
  `.kamal/secrets` and adds `LANTERN_TOKEN` under `env: secret:` in
  `config/deploy.yml`, which is the pair of edits Kamal needs to pass a
  secret through to the containers.

What the generator writes, in every case:

- `config/initializers/lantern.rb`, with every option commented out at
  its default.
- `mount Lantern::Engine, at: "/lantern"` in `config/routes.rb` (the
  beacon endpoint the browser client posts to).
- `.kamal/hooks/post-deploy` — only if `config/deploy.yml` already
  exists.
- `app/frontend/lib/lantern.ts` plus the `startLantern()` call in your
  Inertia entrypoint — only if `app/frontend/` exists. If it can't find
  an entrypoint it prints the two lines to add.
- `require "lantern/rspec"` in `spec/rails_helper.rb`, or
  `require "lantern/minitest"` in `test/test_helper.rb`.

It finishes by running `lantern:doctor` for you, so the install either
ends in a clean checklist or tells you what is still missing.

## 3. Where the token comes from

In Lantern Cloud, create an application, then an environment inside it
(`production`, `staging`, one token each). The token is shown once, on
the page you land on right after creating the environment — copy it
then. If you lose it, rotate it from the environment's settings and
update `LANTERN_TOKEN`.

```sh
bin/rails lantern:token   # prints the URL to create/copy a token
```

A token looks like `lt_` followed by 40 characters. The gem is
completely inert without one: `Lantern.enabled?` is `config.enabled &&
token.present?`, so an app with no token installs no subscribers and
ships nothing.

## 4. Check the wiring

```sh
bin/rails lantern:doctor
```

```
✓ token: lt_9Qv... (43 chars)
✓ ingest url: https://lantern.rebulk.com
✓ ingest reachable: GET https://lantern.rebulk.com/ingest/ping
✓ request middleware: Lantern::Middleware::Request at position 0
✓ engine mounted: POST /lantern/beacon -> lantern/beacon#create
✓ deploy: 8f31c0a (from GIT_REV)
✓ sample rates: requests=1.0 jobs=1.0 commands=1.0 scheduled_tasks=1.0 exceptions=1.0
✓ ignored record types: none
```

It exits non-zero only when the token is missing or the ingest host is
unreachable; the rest of the checklist is informational. Every line and
what to do about a `✗` is in
[`troubleshooting.md`](troubleshooting.md).

`bin/rails lantern:status` is the one-line version: it pings
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
import { startLantern } from "@/lib/lantern"

startLantern()
```

Errors ride the same beacon as visit timing — uncaught errors, unhandled
promise rejections, and Inertia's own `exception` and `invalid` events —
and land as ordinary issues next to your Ruby ones.

If you have React error boundaries, add one more line where the root is
created. React does not report a boundary-caught error to `window.onerror`
outside a development build, so this is the only thing that gets a caught
render error out of production:

```tsx
import { createRoot } from "react-dom/client"
import { lanternRootOptions } from "@/lib/lantern"

createRoot(el, lanternRootOptions()).render(<App {...props} />)
```

On React 18, whose roots take no error options, call
`reportError(error, { componentStack: info.componentStack })` from the
boundary's `componentDidCatch` instead. `startLantern` also takes optional
`ignoreErrors`, `denyUrls`, and `tenant` settings; see
[`docs/configuration.md`](configuration.md) and
[`docs/replacing-sentry.md`](replacing-sentry.md).

**The Kamal post-deploy hook**, for deploy markers and the commit diff
between deploys. Generated at `.kamal/hooks/post-deploy` when
`config/deploy.yml` exists; see the Kamal section below.

**The test matchers**, which turn your suite into a performance gate:

```ruby
# spec/rails_helper.rb
require "lantern/rspec"
```

```ruby
expect { get "/widgets" }.to have_lantern_queries(at_most: 6)
expect { get "/widgets" }.not_to have_lantern_n_plus_one
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
LANTERN_TOKEN=$LANTERN_TOKEN
```

```yaml
# config/deploy.yml
env:
  secret:
    - LANTERN_TOKEN
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
should be reporting). It exits immediately when `LANTERN_TOKEN` isn't
set and never fails a deploy — every network call ends in `|| true`.

Set the optional `LANTERN_DEPLOY_URL` to link the deploy marker at a CI
run or a release page.

### Docker, Heroku, Render

Environment variables only:

```sh
LANTERN_TOKEN=lt_...
LANTERN_INGEST_URL=https://lantern.rebulk.com   # only when self-hosting
LANTERN_DEPLOY=<release identifier>
```

Set `LANTERN_DEPLOY` to whatever your platform calls the thing it just
shipped — `HEROKU_SLUG_COMMIT` on Heroku, `RENDER_GIT_COMMIT` on Render,
your image tag under plain Docker. That value is the release: it lands
on every record, groups the Releases page, and marks the charts.
Without it, `config.deploy` falls back to `KAMAL_VERSION` then `GIT_REV`,
and is nil if neither is set.

### No Kamal

Run the deploy task as a release or post-deploy step, so charts still
get deploy markers:

```sh
bin/rails "lantern:deploy[$GIT_SHA,v42,https://ci.example.com/runs/42]"
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
- [`troubleshooting.md`](troubleshooting.md) — every `lantern:doctor`
  line and what a failure means.
- [`faq.md`](faq.md) — overhead, retention, PII, unreachable platform.
- [`ai-and-mcp.md`](ai-and-mcp.md) — asking an AI assistant what broke.
