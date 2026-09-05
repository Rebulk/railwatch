source "https://rubygems.org"

gemspec

# Compatibility gemfiles set this to one maintained Rails minor. Keeping the
# constraint here means they exercise the exact same development/test bundle
# as the default lockfile instead of a reduced synthetic dependency set.
gem "rails", ENV.fetch("LANTERN_RAILS_REQUIREMENT") if ENV.key?("LANTERN_RAILS_REQUIREMENT")

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
end

group :bench do
  gem "benchmark-ips"
  gem "memory_profiler"
end
