# frozen_string_literal: true

require "net/http"

module Nightrail
  module Patches
    # Outgoing HTTP. Net::HTTP is under Faraday's default adapter, HTTParty,
    # RestClient, and ruby-llm, so one prepend covers most of the ecosystem.
    # Requests to the Nightrail ingest itself are skipped.
    module NetHttp
      REENTRY = :nightrail_net_http

      def request(req, body = nil, &block)
        return super if Thread.current[REENTRY] || !Nightrail.enabled? || nightrail_self_request?
        exe = Nightrail.execution
        # Before the recording? gate: a sampled-out execution still propagates
        # its trace context, just with the "not sampled" flag.
        Nightrail::Patches::NetHttp.propagate_trace(req, address)
        return super if exe && !exe.recording?

        Thread.current[REENTRY] = true
        start = Clock.monotonic
        started_at = Clock.now
        response = nil
        error = nil
        begin
          response = super
        rescue StandardError => e
          error = e
          raise
        ensure
          Thread.current[REENTRY] = nil
          exe&.count(:outgoing_requests)
          Nightrail::Patches::NetHttp.record(self, req, response, error, start, started_at)
        end
      end

      def nightrail_self_request?
        ingest = URI(Nightrail.config.ingest_url)
        address == ingest.host && port == ingest.port
      rescue StandardError
        false
      end

      # Never overwrites a traceparent the app set itself.
      def self.propagate_trace(req, host)
        return if req.key?("traceparent")

        traceparent = Nightrail.traceparent(host)
        req["traceparent"] = traceparent if traceparent
      rescue StandardError => e
        Nightrail.debug { "traceparent propagation failed: #{e.message}" }
      end

      def self.record(http, req, response, error, start, started_at)
        host = http.address
        default_port = http.use_ssl? ? 443 : 80
        url = "#{http.use_ssl? ? 'https' : 'http'}://#{host}#{http.port == default_port ? '' : ":#{http.port}"}#{req.path}"
        Nightrail.record(:outgoing_request,
          group: Record.group_hash(host, req.method),
          timestamp: started_at,
          host: host,
          method: req.method,
          url: Record.url_without_sensitive_components(url, limit: 2048),
          duration: Clock.micros_since(start),
          status_code: response&.code.to_i,
          request_size: (req.body || "").bytesize,
          response_size: response ? (response["Content-Length"]&.to_i || response.body&.bytesize rescue nil) : nil,
          error: error && "#{error.class}: #{error.message}"[0, 255],
          response_body: response_body(response, error),
          source: Backtrace.caller_location(skip: 4))
      rescue StandardError => e
        Nightrail.debug { "outgoing request record failed: #{e.message}" }
      end

      RESPONSE_BODY_MAX = 4096

      def self.response_body(response, error)
        return nil unless Nightrail.config.capture_response_body_on_error
        return nil unless error || response&.code.to_i >= 400

        # Net::HTTPResponse#body reads from the socket the first time it is
        # called, which would consume a response the caller is streaming out
        # of #read_body. @body holds a String only once Net::HTTP has already
        # buffered the whole body (which #request does for every response it
        # isn't streaming), so reading it here can never touch the socket.
        captured_response_body(response&.instance_variable_get(:@body))
      end

      # Shared with Nightrail::Faraday. A JSON object body goes through the
      # same parameter filter as request params and is re-serialized; any
      # other body has no keys to match, so it is stored as it arrived.
      def self.captured_response_body(body)
        return nil unless body.is_a?(String) && !body.empty?

        parsed = (JSON.parse(body) rescue nil)
        body = JSON.generate(Nightrail.redactor.params(parsed)) if parsed.is_a?(Hash)
        body[0, RESPONSE_BODY_MAX]
      end
    end
  end
end
