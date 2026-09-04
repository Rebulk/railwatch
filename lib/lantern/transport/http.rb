# frozen_string_literal: true

require "net/http"
require "zlib"
require "json"

module Lantern
  module Transport
    # POSTs gzip NDJSON batches to the platform. Each call retries one raised
    # error or 5xx response, then returns a classified, non-raising result;
    # Reporter owns retention and backoff between calls. A 401 marks the
    # transport unauthorized so no further requests are made.
    class Http
      RETRYABLE_STATUSES = [ 402, 408, 429 ].freeze
      UNAUTHORIZED_STATUS = 401

      Result = Struct.new(:ok, :status, :accepted, :rejected, :error, keyword_init: true) do
        def retryable?
          !ok && Http.retryable_status?(status)
        end
      end

      def self.retryable_status?(status)
        status.nil? || RETRYABLE_STATUSES.include?(status) || (500..599).cover?(status)
      end

      def initialize(config)
        @config = config
        @uri = URI.join(config.ingest_url, "/ingest")
        @unauthorized = false
      end

      def unauthorized?
        @unauthorized
      end

      def deliver(records, dropped: 0)
        return Result.new(ok: false, status: UNAUTHORIZED_STATUS, error: "unauthorized, flushing stopped") if @unauthorized

        body = encode(records)
        attempt = 0
        begin
          attempt += 1
          result = parse(post(body, dropped))
          result = parse(post(body, dropped)) if attempt < 2 && (500..599).cover?(result.status)
          apply_status_policy(result)
          result
        rescue StandardError => e
          retry if attempt < 2
          Result.new(ok: false, error: "#{e.class}: #{e.message}")
        end
      end

      def ping
        response = request(Net::HTTP::Get.new(URI.join(@config.ingest_url, "/ingest/ping")))
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      private

      def encode(records)
        io = StringIO.new
        gz = Zlib::GzipWriter.new(io)
        records.each { |r| gz.write(JSON.generate(r)); gz.write("\n") }
        gz.close
        io.string
      end

      def post(body, dropped)
        req = Net::HTTP::Post.new(@uri)
        req["Content-Type"] = "application/x-ndjson"
        req["Content-Encoding"] = "gzip"
        req["X-Lantern-Dropped"] = dropped.to_s if dropped.positive?
        req["X-Lantern-Version"] = Lantern::VERSION
        req.body = body
        request(req)
      end

      def request(req)
        req["Authorization"] = "Bearer #{@config.token}"
        req["User-Agent"] = "lantern-ruby/#{Lantern::VERSION}"
        Net::HTTP.start(@uri.host, @uri.port,
                        use_ssl: @uri.scheme == "https",
                        open_timeout: @config.connect_timeout,
                        read_timeout: @config.timeout,
                        write_timeout: @config.timeout) do |http|
          http.request(req)
        end
      end

      def parse(response)
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body) rescue {}
          Result.new(ok: true, status: response.code.to_i, accepted: data["accepted"], rejected: data["rejected"])
        else
          Result.new(ok: false, status: response.code.to_i, error: response.body.to_s[0, 200])
        end
      end

      def apply_status_policy(result)
        case result.status
        when UNAUTHORIZED_STATUS
          @unauthorized = true
          Lantern.debug { "ingest returned 401 -- marking transport unauthorized, no further flushes will be attempted" }
        end
      end
    end
  end
end
