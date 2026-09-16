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

      Result = Struct.new(:ok, :status, :accepted, :rejected, :rejections, :error, :retryable_error, keyword_init: true) do
        def retryable?
          !ok && (retryable_error || Http.retryable_status?(status))
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

      # The object itself is copied into a forked process, but its policy
      # state belongs to the parent that observed those responses.
      def reset_after_fork!
        @unauthorized = false
        self
      end

      # `deadline` is a monotonic instant (Clock.monotonic) after which this
      # call must not still be on the wire: the connect, read, and write
      # timeouts are clamped to what remains of it, the one retry is skipped
      # once it has passed, and a call that starts past it makes no request.
      # Without it a server that accepts connections and never answers costs
      # two full read timeouts per call, which is what turned a wedged
      # Railwatch into ~8s on the exit of every rake task and runner.
      def deliver(records, dropped: 0, dropped_bytes: 0, backpressure_factor: 1.0, batch_id: SecureRandom.uuid,
                  deadline: nil)
        unless @config.ingest_url_allowed?
          return Result.new(ok: false, error: "plain HTTP ingest is disabled; use HTTPS or set RAILWATCH_ALLOW_HTTP=true")
        end
        return Result.new(ok: false, status: UNAUTHORIZED_STATUS, error: "unauthorized, flushing stopped") if @unauthorized

        body, sent, over_cap, over_cap_bytes = encode(records)
        if over_cap.positive?
          # Not a delivery failure: a batch this large will be exactly as
          # large on every retry, so raising a retryable error here would burn
          # the whole ladder and drop the records at the end anyway. Drop them
          # now, and count them onto this batch so the loss is visible.
          Railwatch.debug { "dropped #{over_cap} records that did not fit in batch_bytes (#{@config.batch_bytes})" }
          dropped += over_cap
          dropped_bytes += over_cap_bytes
        end
        if deadline && remaining(deadline) <= 0
          return Result.new(ok: false, error: "delivery deadline passed before the request was sent", retryable_error: true)
        end
        attempt = 0
        begin
          attempt += 1
          result = parse(post(body, dropped, dropped_bytes, backpressure_factor, batch_id, deadline), expected_count: sent)
          if attempt < 2 && (500..599).cover?(result.status) && time_left?(deadline)
            result = parse(post(body, dropped, dropped_bytes, backpressure_factor, batch_id, deadline), expected_count: sent)
          end
          apply_status_policy(result)
          result
        rescue StandardError => e
          retry if attempt < 2 && time_left?(deadline)
          Result.new(ok: false, error: "#{e.class}: #{e.message}")
        end
      end

      def ping
        return false unless @config.ingest_url_allowed?

        response = request(Net::HTTP::Get.new(URI.join(@config.ingest_url, "/ingest/ping")))
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      private

      # The one serialization of the batch, so it is also where its exact
      # uncompressed size is known. Records past config.batch_bytes are left
      # out and reported back to the caller rather than growing the request
      # without limit. Returns [body, records written, records left out,
      # bytes left out].
      def encode(records)
        io = StringIO.new
        gz = Zlib::GzipWriter.new(io)
        bytes = 0
        sent = 0
        over_cap = 0
        over_cap_bytes = 0
        records.each do |record|
          json = JSON.generate(record)
          size = json.bytesize + 1
          if bytes + size > @config.batch_bytes
            over_cap += 1
            over_cap_bytes += size
            next
          end
          gz.write(json)
          gz.write("\n")
          bytes += size
          sent += 1
        end
        gz.close
        [ io.string, sent, over_cap, over_cap_bytes ]
      end

      def remaining(deadline)
        deadline - Clock.monotonic
      end

      def time_left?(deadline)
        deadline.nil? || remaining(deadline).positive?
      end

      def post(body, dropped, dropped_bytes, backpressure_factor, batch_id, deadline = nil)
        req = Net::HTTP::Post.new(@uri)
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
        request(req, deadline)
      end

      def request(req, deadline = nil)
        req["Authorization"] = "Bearer #{@config.token}"
        req["User-Agent"] = "railwatch-ruby/#{Railwatch::VERSION}"
        options = {
          use_ssl: @uri.scheme == "https",
          open_timeout: bounded(@config.connect_timeout, deadline),
          read_timeout: bounded(@config.timeout, deadline),
          write_timeout: bounded(@config.timeout, deadline)
        }
        # Net::HTTP currently defaults HTTPS clients to VERIFY_PEER. Set it
        # explicitly so a Ruby default change cannot silently weaken ingest.
        options[:verify_mode] = OpenSSL::SSL::VERIFY_PEER if options[:use_ssl]
        Net::HTTP.start(@uri.host, @uri.port, **options) do |http|
          http.request(req)
        end
      end

      # Net::HTTP treats a zero timeout as "no timeout", so the floor is a
      # small positive number, not zero.
      def bounded(timeout, deadline)
        return timeout unless deadline

        [ [ remaining(deadline), 0.05 ].max, timeout ].min
      end

      def parse(response, expected_count:)
        if response.is_a?(Net::HTTPSuccess)
          parse_acknowledgement(response, expected_count)
        else
          Result.new(ok: false, status: response.code.to_i, error: response.body.to_s[0, 200])
        end
      end

      def parse_acknowledgement(response, expected_count)
        data = JSON.parse(response.body)
        return invalid_acknowledgement(response, "response must be a JSON object") unless data.is_a?(Hash)

        accepted = data["accepted"]
        rejected = data["rejected"]
        unless accepted.is_a?(Integer) && accepted >= 0 && rejected.is_a?(Integer) && rejected >= 0
          return invalid_acknowledgement(response, "accepted and rejected must be non-negative integers")
        end
        unless drained?(data, accepted, rejected) || accepted + rejected == expected_count
          return invalid_acknowledgement(response,
                                         "accepted + rejected was #{accepted + rejected}, expected #{expected_count}")
        end

        rejections = data["rejections"]
        unless rejections.nil? || rejections.is_a?(Array)
          return invalid_acknowledgement(response, "rejections must be an array when present")
        end

        Result.new(ok: true, status: response.code.to_i, accepted: accepted, rejected: rejected,
                   rejections: Array(rejections).first(10))
      rescue JSON::ParserError => error
        invalid_acknowledgement(response, "invalid JSON (#{error.message})")
      end

      # Ingest can take a whole batch off our hands without storing any of it:
      # a paused or over-quota environment answers 200 with
      # {"accepted":0,"rejected":0,"reason":"paused"}. That batch IS delivered
      # -- the platform decided its fate -- so retrying it would burn eight
      # attempts and drop the records anyway. Any acknowledgement carrying a
      # `reason`, and any all-zero acknowledgement, drains the batch.
      def drained?(data, accepted, rejected)
        data.key?("reason") || (accepted.zero? && rejected.zero?)
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
