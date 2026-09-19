# frozen_string_literal: true

require "net/http"
require "openssl"
require "zlib"
require "json"

module Railwatch
  module Transport
    # POSTs gzip NDJSON batches to the platform. Each call retries one raised
    # error or 5xx response, then returns a classified, non-raising result;
    # Reporter owns retention and backoff between calls. A 401 marks the
    # transport unauthorized so no further requests are made.
    class Http
      RETRYABLE_STATUSES = [ 402, 408, 429 ].freeze
      UNAUTHORIZED_STATUS = 401

      # `reason` and `retry_after_at` are what the receiver said about this
      # delivery beyond its counts: why it was not stored, and when to come
      # back. They are carried rather than discarded so a caller with durable
      # storage can wait instead of guessing.
      Result = Struct.new(:ok, :status, :accepted, :rejected, :rejections, :error, :retryable_error,
                          :reason, :retry_after_at, :disposition, keyword_init: true) do
        def retryable?
          !ok && (retryable_error || Http.retryable_status?(status))
        end

        # The receiver took the batch off our hands without storing it: a
        # paused or over-quota environment. Not a failure, and not storage.
        def deferred? = disposition == :deferred
      end

      def self.retryable_status?(status)
        status.nil? || RETRYABLE_STATUSES.include?(status) || (500..599).cover?(status)
      end

      def initialize(config, endpoint: nil)
        @config = config
        @uri = endpoint ? URI.parse(endpoint) : URI.join(config.ingest_url, "/ingest")
        @unauthorized = false
        @encoder = WireEncoder.new(batch_bytes: config.batch_bytes)
      end

      def unauthorized?
        @unauthorized
      end

      # The object itself is copied into a forked process, but its policy
      # state belongs to the parent that observed those responses.
      def reset_after_fork!
        @unauthorized = false
        self
      end

      def deliver(records, dropped: 0, dropped_bytes: 0, backpressure_factor: 1.0, batch_id: SecureRandom.uuid)
        unless @config.ingest_url_allowed?
          return Result.new(ok: false, error: "plain HTTP ingest is disabled; use HTTPS or set RAILWATCH_ALLOW_HTTP=true")
        end
        return Result.new(ok: false, status: UNAUTHORIZED_STATUS, error: "unauthorized, flushing stopped") if @unauthorized

        encoded = @encoder.encode(records)
        body = encoded.body
        sent = encoded.sent
        over_cap = encoded.over_cap
        over_cap_bytes = encoded.over_cap_bytes
        if over_cap.positive?
          # Not a delivery failure: a batch this large will be exactly as
          # large on every retry, so raising a retryable error here would burn
          # the whole ladder and drop the records at the end anyway. Drop them
          # now, and count them onto this batch so the loss is visible.
          Railwatch.debug { "dropped #{over_cap} records that did not fit in batch_bytes (#{@config.batch_bytes})" }
          dropped += over_cap
          dropped_bytes += over_cap_bytes
        end
        attempt = 0
        begin
          attempt += 1
          result = parse(post(body, dropped, dropped_bytes, backpressure_factor, batch_id), expected_count: sent)
          if attempt < 2 && (500..599).cover?(result.status)
            result = parse(post(body, dropped, dropped_bytes, backpressure_factor, batch_id), expected_count: sent)
          end
          apply_status_policy(result)
          result
        rescue StandardError => e
          retry if attempt < 2
          Result.new(ok: false, error: "#{e.class}: #{e.message}")
        end
      end

      # Sends bytes that were encoded earlier and stored. Exactly one attempt:
      # the caller owns a durable queue and its own retry schedule, and
      # multiplying two ladders together would turn one backoff into sixty-four.
      def deliver_encoded(body:, expected_count:, headers: {}, dropped: 0, dropped_bytes: 0,
                          backpressure_factor: 1.0, batch_id: SecureRandom.uuid)
        unless @config.ingest_url_allowed?
          return Result.new(ok: false, error: "plain HTTP ingest is disabled; use HTTPS or set RAILWATCH_ALLOW_HTTP=true")
        end

        response = post(body, dropped, dropped_bytes, backpressure_factor, batch_id, headers: headers)
        result = parse(response, expected_count: expected_count)
        apply_status_policy(result)
        result
      rescue StandardError => e
        Result.new(ok: false, error: "#{e.class}: #{e.message}", retryable_error: true)
      end

      def ping
        return false unless @config.ingest_url_allowed?

        response = request(Net::HTTP::Get.new(URI.join(@config.ingest_url, "/ingest/ping")))
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      private

      def post(body, dropped, dropped_bytes, backpressure_factor, batch_id, headers: {})
        req = Net::HTTP::Post.new(@uri)
        headers.each { |name, value| req[name] = value.to_s }
        req["Content-Type"] = "application/x-ndjson"
        req["Content-Encoding"] = "gzip"
        req["X-Railwatch-Dropped"] = dropped.to_s if dropped.positive?
        req["X-Railwatch-Dropped-Bytes"] = dropped_bytes.to_s if dropped_bytes.positive?
        if backpressure_factor > 1.0
          req["X-Railwatch-Backpressure-Factor"] = backpressure_factor.to_s
        end
        req["X-Railwatch-Version"] = Railwatch::VERSION
        req["X-Railwatch-Batch-Id"] = batch_id
        req.body = body
        request(req)
      end

      def request(req)
        req["Authorization"] = "Bearer #{@config.token}"
        req["User-Agent"] = "railwatch-ruby/#{Railwatch::VERSION}"
        options = {
          use_ssl: @uri.scheme == "https",
          open_timeout: @config.connect_timeout,
          read_timeout: @config.timeout,
          write_timeout: @config.timeout
        }
        # Net::HTTP currently defaults HTTPS clients to VERIFY_PEER. Set it
        # explicitly so a Ruby default change cannot silently weaken ingest.
        options[:verify_mode] = OpenSSL::SSL::VERIFY_PEER if options[:use_ssl]
        Net::HTTP.start(@uri.host, @uri.port, **options) do |http|
          http.request(req)
        end
      end

      # A receiver in trouble can answer with something enormous -- a proxy
      # error page, a stack trace. Only ever look at the first slice of it.
      MAX_RESPONSE_BYTES = 64 * 1024

      def parse(response, expected_count:)
        if response.is_a?(Net::HTTPSuccess)
          parse_acknowledgement(response, expected_count)
        else
          Result.new(ok: false, status: response.code.to_i, error: body_of(response)[0, 200],
                     retry_after_at: retry_after_at(response))
        end
      end

      def body_of(response)
        response.body.to_s.byteslice(0, MAX_RESPONSE_BYTES).to_s
      end

      # Seconds, or an HTTP date. Anything else is not a delay we can trust,
      # so the caller falls back to its own backoff rather than a guess.
      def retry_after_at(response)
        raw = response["Retry-After"].to_s.strip
        return nil if raw.empty?

        if raw.match?(/\A\d+\z/)
          seconds = raw.to_i
          return nil unless seconds.between?(0, 86_400)

          Time.now + seconds
        else
          parsed = (Time.httpdate(raw) rescue nil)
          parsed&.> (Time.now - 1) ? parsed : nil
        end
      end

      def parse_acknowledgement(response, expected_count)
        data = JSON.parse(body_of(response))
        return invalid_acknowledgement(response, "response must be a JSON object") unless data.is_a?(Hash)

        accepted = data["accepted"]
        rejected = data["rejected"]
        unless accepted.is_a?(Integer) && accepted >= 0 && rejected.is_a?(Integer) && rejected >= 0
          return invalid_acknowledgement(response, "accepted and rejected must be non-negative integers")
        end
        reason = data["reason"].is_a?(String) ? data["reason"][0, 64] : nil
        if reason.nil? && accepted + rejected != expected_count
          return invalid_acknowledgement(response,
                                         "accepted + rejected was #{accepted + rejected}, expected #{expected_count}")
        end

        rejections = data["rejections"]
        unless rejections.nil? || rejections.is_a?(Array)
          return invalid_acknowledgement(response, "rejections must be an array when present")
        end

        Result.new(ok: true, status: response.code.to_i, accepted: accepted, rejected: rejected,
                   rejections: Array(rejections).first(10), reason: reason,
                   retry_after_at: retry_after_at(response),
                   disposition: reason ? :deferred : :stored)
      rescue JSON::ParserError => error
        invalid_acknowledgement(response, "invalid JSON (#{error.message})")
      end

      # A proxy-generated 2xx page or a contract mismatch cannot acknowledge
      # the submitted records. Keep the batch for Reporter retry instead of
      # silently treating it as delivered.
      def invalid_acknowledgement(response, detail)
        Result.new(ok: false, status: response.code.to_i, error: "invalid ingest acknowledgement: #{detail}",
                   retryable_error: true)
      end

      def apply_status_policy(result)
        case result.status
        when UNAUTHORIZED_STATUS
          @unauthorized = true
          Railwatch.debug { "ingest returned 401 -- marking transport unauthorized, no further flushes will be attempted" }
        end
      end
    end
  end
end
