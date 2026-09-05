source "https://rubygems.org"

gemspec

gem "puma"
gem "sqlite3", ">= 2.1"
gem "solid_queue"
gem "solid_cache"
gem "solid_cable"

group :development, :test do
  # Profiler backends (optional at runtime; apps add one to their Gemfile).
  gem "stackprof"
  gem "vernier"
  gem "rspec-rails", "~> 8.0"
  gem "webmock"
  gem "rubocop-rails-omakase", require: false
  gem "debug", require: "debug/prelude"
  gem "inertia_rails", "~> 3.21"
  gem "faraday"
  # Optional at runtime; present here to prove the direct-worker middleware
  # against Sidekiq's real configuration and middleware APIs.
  gem "sidekiq"
end

group :bench do
  gem "benchmark-ips"
  gem "memory_profiler"
end
