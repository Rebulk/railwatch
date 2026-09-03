# Lantern

First-class monitoring for Rails. One gem instruments requests, jobs,
scheduled tasks, commands, queries, exceptions, cache, mail, broadcasts,
outgoing HTTP, storage, views, and logs, links them into one trace per
execution, and ships them to Lantern Cloud with under a millisecond of
overhead per request and zero writes to your database.

```ruby
# Gemfile
gem "lantern"
```

```sh
bin/rails generate lantern:install
LANTERN_TOKEN=lt_... bin/rails lantern:status
```

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
exception ships immediately, bypassing sampling and buffering, so a
crashing process reports even if it never reaches a normal flush.

What differs from a dedicated error tracker: exceptions aren't reported in
isolation — each one is linked (`execution_id`/`trace_id`) to the request,
job, or command it happened inside, alongside every query, cache read,
outgoing request, and log line from that same execution. There's no
separate error-tracking SDK/config to maintain — `severity`, `handled`,
and `context` all come from the same `Lantern.configure` block and
`Lantern.context` calls used for everything else the gem instruments.

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
