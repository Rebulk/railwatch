# frozen_string_literal: true

require "net/http"

module Lantern
  module Patches
    # Outgoing HTTP. Net::HTTP is under Faraday's default adapter, HTTParty,
    # RestClient, and ruby-llm, so one prepend covers most of the ecosystem.
    # Requests to the Lantern ingest itself are skipped.
    module NetHttp
      REENTRY = :lantern_net_http

      def request(req, body = nil, &block)
        return super if Thread.current[REENTRY] || !Lantern.enabled? || lantern_self_request?
        exe = Lantern.execution
        # Before the recording? gate: a sampled-out execution still propagates
        # its trace context, just with the "not sampled" flag.
        Lantern::Patches::NetHttp.propagate_trace(req, address)
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
          Lantern::Patches::NetHttp.record(self, req, response, error, start, started_at)
        end
      end

      def lantern_self_request?
        ingest = URI(Lantern.config.ingest_url)
        address == ingest.host && port == ingest.port
      rescue StandardError
        false
      end

      # Never overwrites a traceparent the app set itself.
      def self.propagate_trace(req, host)
        return if req.key?("traceparent")

        traceparent = Lantern.traceparent(host)
        req["traceparent"] = traceparent if traceparent
      rescue StandardError => e
        Lantern.debug { "traceparent propagation failed: #{e.message}" }
      end

      def self.record(http, req, response, error, start, started_at)
        host = http.address
        default_port = http.use_ssl? ? 443 : 80
        url = "#{http.use_ssl? ? 'https' : 'http'}://#{host}#{http.port == default_port ? '' : ":#{http.port}"}#{req.path.to_s.split('?').first}"
        Lantern.record(:outgoing_request,
          group: Record.group_hash(host, req.method),
          timestamp: started_at,
          host: host,
          method: req.method,
          url: url[0, 2048],
          duration: Clock.micros_since(start),
          status_code: response&.code.to_i,
          request_size: (req.body || "").bytesize,
          response_size: response ? (response["Content-Length"]&.to_i || response.body&.bytesize rescue nil) : nil,
          error: error && "#{error.class}: #{error.message}"[0, 255],
          source: Backtrace.caller_location(skip: 4))
      rescue StandardError => e
        Lantern.debug { "outgoing request record failed: #{e.message}" }
      end
    end
  end
end
