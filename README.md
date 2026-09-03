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
generated `app/frontend/lib/lantern.ts`.

## Development

```sh
bundle install
bundle exec rspec
```
