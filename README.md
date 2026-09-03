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

Framework/vendor noise is excluded by default so a fresh install isn't
dominated by Rails' own housekeeping: default vendor rake tasks (`db:migrate`,
`assets:precompile`, ...) never get a `command` record, and default vendor
cache-key prefixes (`rack::attack`, `flipper`, `active_storage`, ...) never
get a `cache_event` record. Opt back in per app:

```ruby
Lantern.configure do |c|
  c.capture_default_vendor_commands = true     # LANTERN_CAPTURE_DEFAULT_VENDOR_COMMANDS
  c.capture_default_vendor_cache_keys = true    # LANTERN_CAPTURE_DEFAULT_VENDOR_CACHE_KEYS
end
```

Drop your own noisy cache keys the same way, in addition to the vendor list.
A trailing `*` matches as a prefix, a string starting with `^` (or containing
another regex metacharacter) is compiled as a `Regexp`, and anything else must
match the key exactly:

```ruby
Lantern.reject_cache_keys(%w[session: rack::attack* ^feature_flag_\d+$])
```

`Lantern.on_unrecoverable` is Lantern watching itself: it's called whenever an
internal error is rescued (a subscriber raising, or delivery failing after its
retry) instead of only being logged to `Lantern.debug`:

```ruby
Lantern.on_unrecoverable { |error| Rails.error.report(error, handled: true) }
```

Outgoing HTTP made through Faraday is instrumented by adding
`Lantern::Faraday` to the connection's middleware stack (`Net::HTTP` is
already covered globally, with no setup):

```ruby
Faraday.new(url) { |f| f.use Lantern::Faraday }
```

For any other HTTP client, wrap the call directly:

```ruby
Lantern.instrument_outgoing(:get, url) { http_client.get(url) }
```

## Development

```sh
bundle install
bundle exec rspec
```
