# Troubleshooting

Start with `bin/rails railwatch:doctor`. It checks every piece of the
install in one pass and prints a `✓`/`✗` line per piece. The sections
below are keyed to those lines.

```sh
bin/rails railwatch:doctor
```

The task exits non-zero only when **token** or **ingest reachable**
fails. Everything else is informational. A `✗` there means a feature
isn't wired, not that the install is broken.

| Doctor line | What a `✗` means |
|---|---|
| `token` | `RAILWATCH_TOKEN` is unset or empty. Fatal: nothing is recorded at all. |
| `ingest url` | `ingest_url` isn't a parseable HTTP(S) URL. |
| `ingest reachable` | `GET {ingest_url}/ingest/ping` didn't return success. Fatal. The ping carries the token, so a missing or wrong token fails this line too; fix `token` first. |
| `request middleware` | `Railwatch::Middleware::Request` isn't in the stack, so requests aren't executions. |
| `engine mounted` | `mount Railwatch::Engine, at: "/railwatch"` is missing from `config/routes.rb`; the browser beacon has nowhere to post. |
| `deploy` | `config.deploy` is unset — records ship, charts get no deploy markers. |
| `sample rates` | Never fails; it prints the effective rate per execution kind. |
| `ignored record types` | Never fails; it prints what `c.ignore` is dropping. |
| `kamal post-deploy hook` | `.kamal/hooks/post-deploy` is missing or doesn't mention Railwatch. Only matters if you deploy with Kamal. |
| `browser client` | `app/frontend/lib/railwatch.ts` isn't there. Only matters for Inertia visit timing. |
| `browser client imported` | The client exists but nothing calls `startRailwatch()` — no `startRailwatch` found in `app/frontend/entrypoints`. Visits won't report. |
| `profiler backend` | Neither `vernier` nor `stackprof` is installed, so `Railwatch::Profiler.available?` is false and the profiling settings are inert. |
| `test matchers` | Neither `spec/rails_helper.rb` requires `railwatch/rspec` nor `test/test_helper.rb` requires `railwatch/minitest`. |

## No records at all

**Symptom.** The environment's pages stay empty however much traffic the
app takes.

Work down this list. The first five are the same root cause seen from
different angles: Railwatch decided not to record.

**The token is missing or blank.** `Railwatch.enabled?` is
`config.enabled && token.present?`. With no token the engine's
`railwatch.subscribe` initializer returns early, so no subscribers and no
patches are installed at all. This is by design, so the gem is inert in
development. Fix: set `RAILWATCH_TOKEN`, restart, and re-run
`railwatch:doctor`. The `token` line prints the first 6 characters and
the length, which is enough to spot a truncated or quoted value.

**The token is wrong.** A 401 from the ingest marks the transport
permanently unauthorized: no further flush is attempted for the lifetime
of that process. Fixing the env var isn't enough. Restart the process.
`railwatch:doctor`'s `ingest reachable` line catches this before you
deploy.

**`RAILWATCH_INGEST_URL` points somewhere else.** Records go where you sent
them. `railwatch:status` prints the URL it is actually using. Compare it
against the platform you're looking at. Self-hosting: see
[`self-hosting.md`](self-hosting.md).

**`config.enabled` is false.** `RAILWATCH_ENABLED=0` (or `false`/`no`/`off`)
turns everything off with a valid token present.

**Sample rates are at zero.** `c.sample = { requests: 0.0 }` means no
request records. So does the per-route `railwatch_never_sample` macro on
a controller. The `sample rates` doctor line prints the effective
values. Note that an unhandled exception still ships from a sampled-out
execution. So "exceptions arrive but nothing else does" is the
signature of a low sample rate rather than a broken install.

**The record type is ignored.** `c.ignore` drops a type before it is
built. The `ignored record types` doctor line prints the list. Ignoring
`:queries` also drops `n_plus_one`, since both key off `:queries`.

**You're looking at the test environment.** Requiring `railwatch/rspec`
(or `railwatch/minitest`) swaps the reporter's transport for an in-memory
one. A suite records normally but never sends anything over the
network. Independently: the health sampler, the session flusher, and the
profiler all refuse to start when `Rails.env.test?`.

Still nothing? Set `RAILWATCH_DEBUG=1` and restart. Internal diagnostics go
to stderr prefixed `[railwatch]`. They never go to `Rails.logger`, so they
can't become `log` records about themselves. `Railwatch.on_unrecoverable
{ |e| ... }` gets the same failures as a callback.

## Doubled scheduled_task records

**Symptom.** Every recurring task shows twice on the Scheduled tasks
page, at the same minute, usually with different `drift`.

**Cause.** Two Solid Queue supervisors are running against the same
queue database. That could be a stale `bin/jobs` left over from a
previous `bin/dev`, `SOLID_QUEUE_IN_PUMA=true` while a dedicated job role
is also booted, or two containers of the job role. Each supervisor has
its own recurring scheduler and its own workers, so the job really is
performed twice. Railwatch doesn't dedupe: it records one
`scheduled_task` per `perform.active_job`, in whichever process performed
it. The doubled rows are a true report of a doubled run.

**Fix.** Run one supervisor. `SolidQueue::Process.where(kind:
"Supervisor")` tells you how many think they're alive. `bin/kamal app
logs -r job` tells you which containers are booting one. The same
duplication also doubles the work itself, so this is worth fixing
regardless of what the dashboard says.

## Outgoing requests missing in specs

**Symptom.** `have_railwatch_outgoing_requests` never sees anything, and no
`outgoing_request` records appear from the test suite. Production is
fine.

**Cause.** WebMock replaces `::Net::HTTP` with a subclass whose
`#request` short-circuits before calling `super`, so Railwatch's prepend on
the real class never runs.

**Fix.** Re-prepend the patch onto the replacement, once, before the
suite. This is exactly what the gem's own suite does, in
`spec/spec_helper.rb`. App suites using WebMock should do the same:

```ruby
# WebMock replaces ::Net::HTTP with a subclass whose #request short-circuits
# before calling super, so Railwatch's prepend on the real class never runs
# under WebMock. Re-prepend on the replacement so outgoing requests are still
# observed in this suite. Apps using WebMock in their own tests would do the same.
RSpec.configure do |config|
  config.before(:suite) { Net::HTTP.prepend(Railwatch::Patches::NetHttp) }
end
```

## Puma cluster mode: threads after fork

**Symptom.** You expect to have to re-arm something in
`on_worker_boot`, or the Processes page shows fewer processes than you
have workers.

**What actually happens.** Ruby routes `fork`, `Process.fork`, and
`Kernel#fork` through `Process._fork`. Railwatch registers one callback
with Rails' own `ActiveSupport::ForkTracker`, the same hook Active Record
uses to reset its connection pools. Before the child returns from
`fork`, it replaces the inherited reporter buffer, drop accounting,
transport policy state, mutexes, condition variables, dead threads, and the
profiler's process-global state. A parent's in-flight profile would
otherwise leave the child permanently unable to profile.
The parent's half-finished session map is discarded too. The child then
emits its own `process` record and starts fresh health/session threads for
its role. Parent records remain owned by and delivered from the parent.
They can never be replayed by every child. **No `on_worker_boot`
configuration is needed**, in Puma cluster mode or in Solid Queue's
forked workers.

The synchronization objects are replaced without locking them. That is
deliberate. If another parent thread owned a mutex at the instant of
`fork`, Ruby preserves the locked mutex in the child but not the thread
that could unlock it.

**When a process legitimately reports nothing.** `Health.start!` returns
early unless the process's role is `web` or `worker`, and
`Sessions.start!` only runs for `web`. Role detection is
`Railwatch::Subscribers::ProcessInfo.role`, in this order. First `worker`,
when Solid Queue is loaded and `$PROGRAM_NAME` includes `"jobs"` (or the
command starts with `solid_queue:`). Then `console`. Then `command`, when
`$PROGRAM_NAME` ends in `rake`. Then `web`, when Puma is defined. Else
`process`. The worker check comes first deliberately, because Puma is
loaded in a job container too. A console or a rake task ships no health
records by design, and both modules also return early in the `test` env.

## Memory growth with tail sampling on

**Symptom.** RSS climbs after enabling `c.tail_sample_slow_ms`, or the
`peak_memory` on parent records rises across the board.

**Cause.** That is the trade-off, not a leak. With head sampling only, a
sampled-out execution builds and buffers nothing. With tail sampling on,
*every* execution buffers its child records for its whole lifetime:
queries, cache events, logs, view renders. The keep-or-discard decision
can't be made until it ends.

**What to check.**

- Per execution, the buffer is capped at `Execution::MAX_RECORDS`
  (10,000). Past that, records are dropped and counted. The count is
  added to the reporter's drop counter so the loss is visible on the
  platform rather than silent.
- `c.buffer_size` (default 10,000, the same as `MAX_RECORDS`) caps the
  process-wide queue between the app and the reporter thread.
  Oldest-dropped-first, also counted. Do not set it below `MAX_RECORDS`.
  An execution's tree is written to the queue in one go when it ends, so
  a tree larger than the queue loses its own first records. Typically
  those are the outgoing requests a long job made before it started
  writing. Keeping far more executions than before means far more
  records arriving at this queue. Raise it, or lower what you keep.
- `c.profile_slow_ms` compounds it. It profiles every tail-buffering
  execution from its first line and throws away the fast ones, so the
  profiler's stack table is held alongside the record buffer.
- `c.failure_context` buffers sampled-out executions too, but a ring of
  that many records each rather than all of them. If RSS climbed after
  setting it, lower the count. It is a per-execution bound, so the
  process-wide cost is that many records times the executions running
  concurrently.

**Fix.** Lower `tail_sample_slow_ms` so fewer executions qualify to be
buffered. Or drop the highest-volume child types for tail-kept traffic
with `c.ignore`. Or use `Railwatch.keep!` on the specific paths you care
about instead of a global threshold.

## Profiles never appear

**Symptom.** `c.profile_sample` is set but no `profile` records ship and
no request is marked `profiled`.

**Cause.** No profiler backend is installed. Railwatch doesn't vendor one.
`Railwatch::Profiler.available?` is false unless `vernier` or `stackprof`
loads, and every profiling setting is inert while it is. The doctor's
`profiler backend` line reports this.

**Fix.** Add `gem "vernier"` (Ruby ≥ 3.2, preferred) or
`gem "stackprof"`. Two other reasons a profile can be absent even with a
backend. One is `c.profiler` pinned to a name that doesn't load; profiling
stays off rather than falling back. The other is the `test` env, where
profiling is skipped unless `profile_sample` is explicitly non-zero. Both
backends are process-global, so an execution that starts while another
one is being profiled is simply not profiled. That is expected, not a
bug.

## No deploy marker on the charts

**Symptom.** Charts have no vertical deploy lines; the Releases page
groups everything under one blank release.

**Cause.** `config.deploy` is unset. The doctor's `deploy` line says so.
When it is set, the line names the environment variable, `REVISION`, Git
checkout, or initializer it came from.

**Fix.** Set one of them; they are read in this order:

1. `RAILWATCH_DEPLOY`, the explicit override on any platform.
2. `KAMAL_VERSION`.
3. `GIT_REV`, `GIT_SHA`, `SOURCE_VERSION`, `HEROKU_SLUG_COMMIT`,
   `RENDER_GIT_COMMIT`, the tag from `FLY_IMAGE_REF`,
   `VERCEL_GIT_COMMIT_SHA`, `CI_COMMIT_SHA`, or `GITHUB_SHA`.
4. A Capistrano `REVISION` file.
5. `.git/HEAD`, resolved through a loose ref or `packed-refs` without a Git
   subprocess.

Full 40-character SHAs are shortened to 12 characters. Or assign `deploy` in
the initializer. Set `detect_deploy`/`RAILWATCH_DETECT_DEPLOY` to false to ignore
steps 3–5. The value is stamped on every record, so a change only affects
records shipped after the restart. Note that
`config.deploy` and the deploy *marker* are two different things. The
marker, with its commit list, comes from `railwatch:deploy` or the Kamal
hook below.

## The Kamal hook doesn't fire

**Symptom.** Deploys happen; the Deploys page doesn't grow.

**Cause and fix**, in the order the hook itself checks:

- **`RAILWATCH_TOKEN` isn't exported to the hook.** The first thing
  `.kamal/hooks/post-deploy` does is `[ -z "$RAILWATCH_TOKEN" ] && exit 0`.
  The hook runs on the deployer machine, in your shell, not in a
  container. So a token that only exists in `.kamal/secrets` for the
  *app* isn't necessarily in the deployer's environment. Export it there,
  or source the same secret store your CI uses.
- **`curl` or `ruby` isn't on the deployer, or `RAILWATCH_INGEST_URL`
  isn't set.** Then the hook falls back to
  `bin/kamal app exec --primary --reuse "bin/rails railwatch:deploy[$KAMAL_VERSION]"`,
  which records the same deploy **minus the commit list**. A container
  has the code but not the git history. If your deploys show up without
  commits, this is the path you're on.
- **The hook isn't there.** The install generator only writes it when
  `config/deploy.yml` already exists. Re-run
  `bin/rails generate railwatch:install` after adopting Kamal.

The hook never fails a deploy: every network call ends in `|| true`, and
it exits 0 regardless.

## Log search finds less than it should

**Symptom.** On a Postgres-backed platform install, log search matches
fewer lines and highlights nothing.

**Cause.** Full-text search uses SQLite's FTS5 (`logs_fts`). The
platform checks for both a SQLite adapter *and* the `logs_fts` table.
When either is absent it falls back to `message LIKE '%...%'`. That
fallback is a plain substring match: no phrase or negation syntax, and no
snippet highlighting.

**Fix.** Nothing on the gem side; this is a property of the platform's
telemetry store. SQLite is the default and first-class target for
per-environment telemetry precisely because of features like this. A
telemetry database created before the FTS index existed also falls back. A
self-hosted platform operator should rebuild the documented search index.

## The Tenants page is empty

**Symptom.** Every other page has data; Tenants shows nothing.

**Cause.** `tenant` is a column on every telemetry row, filled from
`Railwatch::Context.current_tenant`. A tenant only exists as a GROUP BY
over those rows. If nothing ever sets it, every row has a null tenant and
there is nothing to group.

**Fix.** Apps on `activerecord-tenanted` get it free. Railwatch reads
`ActiveRecord::Base.current_tenant` / `TenantRecord.current_tenant` with
no configuration. Everyone else sets it explicitly, as early in the
request as the tenant is known:

```ruby
Railwatch.context(tenant: org.slug)
```

Set it in the same `before_action` that resolves the tenant, so every
record in the execution carries it. Context set after a record is built
does not retroactively apply to it.

## See also

- [`configuration.md`](configuration.md): every option and its default.
- [`records.md`](records.md): what each record type contains.
- [`faq.md`](faq.md): overhead, retention, PII, and what happens when
  the platform is unreachable.
