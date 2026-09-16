# frozen_string_literal: true

module Railwatch
  require "zlib"
  require "stringio"

  module Ingest
    # Decodes the gem's wire format: optionally gzipped NDJSON.
    module Payload
      class Malformed < StandardError; end
      MAX_BYTES = IngestRequestBodyLimit::MAX_BYTES
      MAX_RECORDS = 20_000
      READ_SIZE = 64.kilobytes

      module_function

      def parse(request)
        declared_bytes = request.content_length
        raise Malformed, "body too large" if declared_bytes && declared_bytes > MAX_BYTES

        raw = read_bounded(request.body)
        raise Malformed, "empty body" if raw.blank?

        records = []
        pending = String.new(encoding: Encoding::BINARY)
        decoded_bytes = 0
        each_decoded_chunk(raw, gzip: request.headers["Content-Encoding"].to_s.include?("gzip")) do |chunk|
          decoded_bytes += chunk.bytesize
          raise Malformed, "payload too large" if decoded_bytes > MAX_BYTES

          pending << chunk
          pending = consume_complete_lines(pending, records)
        end
        append_record(pending, records)
        records
      rescue Zlib::Error => e
        raise Malformed, "bad gzip: #{e.message}"
      rescue JSON::ParserError => e
        raise Malformed, "bad json: #{e.message}"
      end

      def read_bounded(io)
        body = String.new(encoding: Encoding::BINARY)
        loop do
          chunk = io.read([ READ_SIZE, (MAX_BYTES + 1) - body.bytesize ].min)
          break if chunk.nil? || chunk.empty?

          body << chunk
          raise Malformed, "body too large" if body.bytesize > MAX_BYTES
        end
        body
      end

      def each_decoded_chunk(raw, gzip:)
        return each_plain_chunk(raw) { |chunk| yield chunk } unless gzip

        reader = Zlib::GzipReader.new(StringIO.new(raw))
        remaining = MAX_BYTES + 1
        loop do
          chunk = reader.readpartial([ READ_SIZE, remaining ].min)
          remaining -= chunk.bytesize
          yield chunk
        end
      rescue EOFError
        nil
      ensure
        reader&.close
      end

      def each_plain_chunk(raw)
        offset = 0
        while offset < raw.bytesize
          yield raw.byteslice(offset, READ_SIZE)
          offset += READ_SIZE
        end
      end

      def consume_complete_lines(buffer, records)
        offset = 0
        while (newline = buffer.index("\n", offset))
          append_record(buffer.byteslice(offset, newline - offset), records)
          offset = newline + 1
        end
        offset.zero? ? buffer : buffer.byteslice(offset..)
      end

      def append_record(line, records)
        line = line.strip
        return if line.empty?
        raise Malformed, "too many records" if records.size >= MAX_RECORDS

        records << JSON.parse(line)
      end
    end
  end
end
