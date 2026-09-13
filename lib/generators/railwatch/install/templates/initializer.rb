# frozen_string_literal: true

# Railwatch: first-class monitoring for Rails. Every option here can also be
# set by the RAILWATCH_* env var named in the comment.
Railwatch.configure do |c|
  # c.token = ENV["RAILWATCH_TOKEN"]                    # RAILWATCH_TOKEN (required)
  # c.ingest_url = "https://railwatch.rebulk.com"     # RAILWATCH_INGEST_URL
  # c.deploy = "release-name"                       # RAILWATCH_DEPLOY; platform/Git auto-detected
  # c.detect_deploy = false                         # RAILWATCH_DETECT_DEPLOY; default true

  # Sampling is decided once per execution; a sampled-in request ships its
  # whole tree of queries, cache events, jobs, mail, and logs.
  # c.sample = { requests: 1.0, jobs: 1.0, commands: 1.0, scheduled_tasks: 1.0, channels: 1.0, exceptions: 1.0 }

  # Drop whole record types: :queries, :cache_events, :mail, :broadcasts,
  # :notifications, :outgoing_requests, :storage_ops, :view_renders, :logs, :transactions
  # c.ignore = []

  # Default vendor rake tasks (db:migrate, assets:precompile, ...) and default
  # vendor cache-key prefixes (rack::attack, flipper, ...) are excluded unless
  # you opt back in.
  # c.capture_default_vendor_commands = false    # RAILWATCH_CAPTURE_DEFAULT_VENDOR_COMMANDS
  # c.capture_default_vendor_cache_keys = false  # RAILWATCH_CAPTURE_DEFAULT_VENDOR_CACHE_KEYS

  # c.log_level = :info
  # c.buffer_bytes = 16 * 1024 * 1024   # reporter queue memory ceiling
  # c.execution_buffer_bytes = 8 * 1024 * 1024
  # c.batch_bytes = 8 * 1024 * 1024     # uncompressed NDJSON per request
  # c.backpressure = true               # adapt sampling under buffer/ingest pressure
  # c.backpressure_high_water = 0.8     # fraction of either buffer ceiling
  # c.capture_request_payload = false   # only captured for requests that raised, always redacted
  # Retried job errors are usually expected, so they are not captured by
  # default; enabling this can flood the issues list when retries are common.
  # c.capture_job_retry_errors = false  # RAILWATCH_CAPTURE_JOB_RETRY_ERRORS
  # c.redact_headers += %w[X-Api-Key]
  # c.redact_params  += %w[ssn]         # merged with Rails.application.config.filter_parameters
  # c.ignored_request_paths += ["/internal/health"] # /up and /railwatch/beacon are ignored by default

  # How the current user is described. Default reads Current.user then Warden.
  # c.user { |user| { id: user.id, name: user.name, email: user.email } }
end

# A trailing "*" matches as a prefix; a string starting with "^" (or another
# regex metacharacter) is compiled as a Regexp; anything else must match the
# cache key exactly.
# Railwatch.reject_cache_keys %w[session: rack::attack* ^feature_flag_\d+$]
# Railwatch.reject_outgoing_requests { |r| r[:host] == "127.0.0.1" }
# Railwatch.redact_queries { |q| q[:sql] = q[:sql].gsub(/email = '[^']+'/, "email = '?'") }
# Railwatch.before_ingest { |batch| batch.size < 10_000 }   # return false to drop a batch

# Called whenever Railwatch rescues one of its own internal errors (a
# subscriber raising, or delivery failing after its retry), instead of only
# logging to Railwatch.debug.
# Railwatch.on_unrecoverable { |error| Rails.error.report(error, handled: true) }
