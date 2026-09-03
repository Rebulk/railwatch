# frozen_string_literal: true

# Lantern: first-class monitoring for Rails. Every option here can also be
# set by the LANTERN_* env var named in the comment.
Lantern.configure do |c|
  # c.token = ENV["LANTERN_TOKEN"]                    # LANTERN_TOKEN (required)
  # c.ingest_url = "https://lantern.rebulk.com"     # LANTERN_INGEST_URL
  # c.deploy = ENV["KAMAL_VERSION"]                 # LANTERN_DEPLOY; auto-detected from Kamal

  # Sampling is decided once per execution; a sampled-in request ships its
  # whole tree of queries, cache events, jobs, mail, and logs.
  # c.sample = { requests: 1.0, jobs: 1.0, commands: 1.0, scheduled_tasks: 1.0, exceptions: 1.0 }

  # Drop whole record types: :queries, :cache_events, :mail, :broadcasts,
  # :notifications, :outgoing_requests, :storage_ops, :view_renders, :logs, :transactions
  # c.ignore = []

  # c.log_level = :info
  # c.capture_request_payload = false   # only captured for requests that raised, always redacted
  # c.redact_headers += %w[X-Api-Key]
  # c.redact_params  += %w[ssn]         # merged with Rails.application.config.filter_parameters

  # How the current user is described. Default reads Current.user then Warden.
  # c.user { |user| { id: user.id, name: user.name, email: user.email } }
end

# Lantern.reject_cache_keys %w[rack::attack flipper/]
# Lantern.reject_outgoing_requests { |r| r[:host] == "127.0.0.1" }
# Lantern.redact_queries { |q| q[:sql] = q[:sql].gsub(/email = '[^']+'/, "email = '?'") }
# Lantern.before_ingest { |batch| batch.size < 10_000 }   # return false to drop a batch
