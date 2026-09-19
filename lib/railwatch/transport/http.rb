# frozen_string_literal: true

require "net/http"
require "time"
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
                          :reason, :retry_after_at, :disposition, :ack_disposition, keyword_init: true) do
        def retryable?
          # A permanent failure says so outright: without this, its absent
          # status would read as "no response yet", which is retryable.
          return false if disposition == :permanent

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
        unless destination_allowed?
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
      def deliver_encoded(body:, expected_count:, batch_id:, headers: {}, dropped: 0, dropped_bytes: 0,
                          backpressure_factor: 1.0, gem_version: Railwatch::VERSION)
        unless destination_allowed?
          return permanent("plain HTTP ingest is disabled; use HTTPS or set RAILWATCH_ALLOW_HTTP=true")
        end
        # The same latch deliver honours. A caller with its own queue would
        # otherwise keep presenting a token the receiver has already refused.
        return permanent("unauthorized, flushing stopped", status: UNAUTHORIZED_STATUS) if @unauthorized

        response = post(body, dropped, dropped_bytes, backpressure_factor, batch_id,
                        headers: headers, gem_version: gem_version)
        result = parse(response, expected_count: expected_count)
        apply_status_policy(result)
        result
      rescue ArgumentError, URI::Error, TypeError, NoMethodError => e
        # Bad input or bad configuration, not a bad network. Retrying the same
        # stored bytes cannot fix it, and a durable queue would retry forever.
        permanent("#{e.class}: #{e.message}")
      rescue StandardError => e
        Result.new(ok: false, error: "#{e.class}: #{e.message}", retryable_error: true)
      end

      def ping
        return false unless destination_allowed?

        response = request(Net::HTTP::Get.new(URI.join(@config.ingest_url, "/ingest/ping")))
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      private

      def destination_allowed? = @config.url_allowed?(@uri)

      # A failure the caller must not retry: nothing about repeating it can
      # change the outcome. `retryable?` treats a nil status as transient, so
      # these say so explicitly.
      def permanent(error, status: nil)
        Result.new(ok: false, status: status, error: error, retryable_error: false, disposition: :permanent)
      end

      def post(body, dropped, dropped_bytes, backpressure_factor, batch_id, headers: {},
               gem_version: Railwatch::VERSION)
        req = Net::HTTP::Post.new(@uri)
        headers.each { |name, value| req[name] = value.to_s }
        req["Content-Type"] = "application/x-ndjson"
        req["Content-Encoding"] = "gzip"
        req["X-Railwatch-Dropped"] = dropped.to_s if dropped.positive?
        req["X-Railwatch-Dropped-Bytes"] = dropped_bytes.to_s if dropped_bytes.positive?
        if backpressure_factor > 1.0
          req["X-Railwatch-Backpressure-Factor"] = backpressure_factor.to_s
        end
        # The version this payload was built by, which for a stored delivery is
        # not the version running now. The receiver digests this header, so
        # sending today's value would turn an upgrade into a conflict and
        # destroy a delivery it had already accepted.
        req["X-Railwatch-Version"] = gem_version
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
          write_timeout: @config.timeout,
          # POST is not in Net::HTTP's idempotent retry set, but say so:
          # a caller with its own queue must be able to trust "one attempt".
          max_retries: 0
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
      # The longest delay we will take from a receiver, in either spelling.
      MAX_RETRY_AFTER = 86_400

      def parse(response, expected_count:)
        if response.is_a?(Net::HTTPSuccess)
          parse_acknowledgement(response, expected_count)
        else
          Result.new(ok: false, status: response.code.to_i, error: summarize(response.body),
                     retry_after_at: retry_after_at(response))
        end
      end

      # Bounds what we keep and log, not what Net::HTTP already read off the
      # socket -- it buffers the whole response before we ever see it.
      def summarize(body) = body.to_s.byteslice(0, 200).to_s.scrub

      # Seconds, or an HTTP date. Anything else is not a delay we can trust,
      # so the caller falls back to its own backoff rather than a guess.
      def retry_after_at(response)
        raw = response["Retry-After"].to_s.strip
        return nil if raw.empty?

        now = Time.now
        if raw.match?(/\A\d{1,7}\z/)
          seconds = raw.to_i
          seconds <= MAX_RETRY_AFTER ? now + seconds : nil
        else
          parsed = begin
            Time.httpdate(raw)
          rescue ArgumentError
            nil
          end
          return nil unless parsed
          # One second of slack for whole-second HTTP-date precision, and the
          # same ceiling the numeric form gets: a far-future date must not
          # park a delivery for years.
          parsed.between?(now - 1, now + MAX_RETRY_AFTER) ? parsed : nil
        end
      end

      def parse_acknowledgement(response, expected_count)
        body = response.body.to_s
        # Refused whole rather than parsed in part: truncating first would let
        # a padded prefix parse as a complete document, and would reject a
        # large but valid acknowledgement as malformed JSON.
        if body.bytesize > MAX_RESPONSE_BYTES
          return invalid_acknowledgement(response, "acknowledgement larger than #{MAX_RESPONSE_BYTES} bytes")
        end

        data = JSON.parse(body)
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
                   disposition: reason ? :deferred : :stored,
                   ack_disposition: data["disposition"].is_a?(String) ? data["disposition"][0, 32] : nil)
      rescue JSON::ParserError
        # The parser's message quotes the document, which may be a proxy page
        # echoing the request. Say what happened, not what it contained.
        invalid_acknowledgement(response, "invalid JSON")
      end

      # A proxy-generated 2xx page or a contract mismatch cannot acknowledge
      # the submitted records. Keep the batch for Reporter retry instead of
      # silently treating it as delivered.
      def invalid_acknowledgement(response, detail)
        # Keep the delay even though we could not read the rest: a receiver
        # asking for room still means it, whatever state its body was in.
        Result.new(ok: false, status: response.code.to_i, error: "invalid ingest acknowledgement: #{detail}",
                   retryable_error: true, retry_after_at: retry_after_at(response))
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
