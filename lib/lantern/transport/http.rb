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

      def deliver(records, dropped: 0, dropped_bytes: 0, batch_id: SecureRandom.uuid)
        return Result.new(ok: false, status: UNAUTHORIZED_STATUS, error: "unauthorized, flushing stopped") if @unauthorized

        body, sent, over_cap, over_cap_bytes = encode(records)
        if over_cap.positive?
          # Not a delivery failure: a batch this large will be exactly as
          # large on every retry, so raising a retryable error here would burn
          # the whole ladder and drop the records at the end anyway. Drop them
          # now, and count them onto this batch so the loss is visible.
          Lantern.debug { "dropped #{over_cap} records that did not fit in batch_bytes (#{@config.batch_bytes})" }
          dropped += over_cap
          dropped_bytes += over_cap_bytes
        end
        attempt = 0
        begin
          attempt += 1
          result = parse(post(body, dropped, dropped_bytes, batch_id), expected_count: sent)
          result = parse(post(body, dropped, dropped_bytes, batch_id), expected_count: sent) if attempt < 2 && (500..599).cover?(result.status)
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

      def post(body, dropped, dropped_bytes, batch_id)
        req = Net::HTTP::Post.new(@uri)
        req["Content-Type"] = "application/x-ndjson"
        req["Content-Encoding"] = "gzip"
        req["X-Lantern-Dropped"] = dropped.to_s if dropped.positive?
        req["X-Lantern-Dropped-Bytes"] = dropped_bytes.to_s if dropped_bytes.positive?
        req["X-Lantern-Version"] = Lantern::VERSION
        req["X-Lantern-Batch-Id"] = batch_id
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
          Lantern.debug { "ingest returned 401 -- marking transport unauthorized, no further flushes will be attempted" }
        end
      end
    end
  end
end
