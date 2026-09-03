# frozen_string_literal: true

module Lantern
  # Outgoing-request instrumentation for apps built on Faraday instead of
  # (or in addition to) Net::HTTP. Opt in per connection:
  #
  #   Faraday.new(url) { |f| f.use Lantern::Faraday }
  #
  # Overrides #call directly instead of Faraday::Middleware's on_request/
  # on_complete/on_error hooks: middleware instances are built once and
  # reused across every request on that connection, so per-request timing
  # state has to live on the local call stack, not on an instance variable.
  class Faraday < ::Faraday::Middleware
    def call(env)
      start = Clock.monotonic
      started_at = Clock.now
      @app.call(env).on_complete do |response_env|
        record(response_env, start, started_at)
      end
    rescue StandardError => e
      record(env, start, started_at, error: e)
      raise
    end

    private

    def record(env, start, started_at, error: nil)
      url = env.url
      Lantern.record(:outgoing_request, group: Record.group_hash(url.host, env.method.to_s.upcase),
                     timestamp: started_at, host: url.host, method: env.method.to_s.upcase,
                     url: "#{url.scheme}://#{url.host}#{url.path}"[0, 2048],
                     duration: Clock.micros_since(start), status_code: env.status.to_i,
                     error: error && "#{error.class}: #{error.message}"[0, 255])
    end
  end
end
