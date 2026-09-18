# frozen_string_literal: true

module Railwatch
  require "stringio"
  require "zlib"

  module Telemetry
    # Reads untrusted gzip streams without ever asking zlib for more than the
    # configured output ceiling. Ingest uses verify! without retaining the
    # expanded bytes; read paths either return a bounded body or a bounded
    # prefix for displays that can be truncated.
    module BoundedGzip
      READ_SIZE = 64.kilobytes

      class Error < ArgumentError; end
      class Malformed < Error; end
      class TooLarge < Error; end
      class SizeMismatch < Error; end

      module_function

      def decompress(compressed, max_bytes:)
        output = String.new(encoding: Encoding::BINARY)
        each_chunk(compressed, max_bytes: max_bytes) { |chunk| output << chunk }
        output
      end

      # Returns [prefix, truncated?]. Once one byte beyond the display limit is
      # observed, decompression stops instead of expanding the rest of a legacy
      # gzip bomb merely to prove that it was truncated.
      def decompress_capped(compressed, limit:)
        output = String.new(encoding: Encoding::BINARY)
        each_chunk(compressed, max_bytes: limit) { |chunk| output << chunk }
        [ output, false ]
      rescue TooLarge
        [ output, true ]
      end

      def verify!(compressed, max_bytes:, expected_bytes:, utf8: false)
        unless expected_bytes.is_a?(Integer) && expected_bytes.between?(0, max_bytes)
          raise SizeMismatch, "declared size #{expected_bytes} exceeds the #{max_bytes} byte ceiling"
        end

        validator = Encoding::Converter.new(Encoding::UTF_8, Encoding::UTF_16LE) if utf8
        actual_bytes = each_chunk(compressed, max_bytes: max_bytes) do |chunk|
          validator&.convert(chunk)
        end
        validator&.finish
        return actual_bytes if actual_bytes == expected_bytes

        raise SizeMismatch, "declared size #{expected_bytes} does not match decompressed size #{actual_bytes}"
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise Malformed, "decompressed content is not valid UTF-8"
      end

      def utf8!(text)
        text.force_encoding(Encoding::UTF_8)
        return text if text.valid_encoding?

        raise Malformed, "decompressed content is not valid UTF-8"
      end

      def each_chunk(compressed, max_bytes:)
        raise ArgumentError, "max_bytes must be non-negative" unless max_bytes.is_a?(Integer) && max_bytes >= 0

        # StringIO and zlib operate on bytes regardless of the String's
        # encoding. Avoid String#b here: it duplicates even an already-binary
        # database BLOB, adding another full compressed-body allocation.
        source = StringIO.new(compressed.to_s)
        reader = Zlib::GzipReader.new(source)
        total = 0
        loop do
          # The extra byte proves that a stream at the boundary has ended. Only
          # the portion up to the ceiling is ever yielded or retained.
          chunk = reader.readpartial([ READ_SIZE, max_bytes - total + 1 ].min)
          if total + chunk.bytesize > max_bytes
            remaining = max_bytes - total
            yield chunk.byteslice(0, remaining) if remaining.positive?
            raise TooLarge, "decompressed content exceeds #{max_bytes} bytes"
          end

          total += chunk.bytesize
          yield chunk
        end
      rescue EOFError
        # GzipReader reads ahead in fixed-size blocks. `unused` catches bytes
        # already buffered past the gzip member; checking the underlying IO is
        # also required when the member ends exactly on a read boundary and
        # the trailing bytes have not been pulled into zlib's buffer yet.
        raise Malformed, "gzip stream has trailing data" if reader.unused.present? || !source.eof?

        total
      rescue Zlib::Error => e
        raise Malformed, "invalid gzip stream: #{e.message}"
      ensure
        reader&.close
      end
      private_class_method :each_chunk
    end
  end
end
