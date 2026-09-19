# frozen_string_literal: true

require "zlib"
require "stringio"
require "json"
require "digest"

module Railwatch
  module Transport
    # Turns records into the wire body: gzipped NDJSON, one record per line.
    #
    # Lifted out of Transport::Http so a durable queue can hold the encoded
    # bytes and send them later without re-encoding. A retry has to be the
    # same delivery, which means the same bytes, which means encoding is
    # something you do once and keep -- not something you redo per attempt.
    class WireEncoder
      # What one encode produced. `over_cap` records did not fit and were
      # left out; the caller counts them as dropped rather than growing the
      # request without limit, since they would not fit on a retry either.
      Encoded = Struct.new(:body, :sha256, :sent, :over_cap, :over_cap_bytes, :uncompressed_bytes,
                           keyword_init: true)

      def initialize(batch_bytes:)
        @batch_bytes = batch_bytes
      end

      def encode(records)
        io = StringIO.new
        # mtime 0 so encoding the same records twice on this runtime gives the
        # same bytes, rather than differing by the second they were encoded.
        # It is not a portability guarantee -- zlib builds may deflate
        # identical input differently -- which is why a stored delivery keeps
        # its bytes and its digest rather than re-deriving them later.
        gz = Zlib::GzipWriter.new(io, Zlib::DEFAULT_COMPRESSION, Zlib::DEFAULT_STRATEGY)
        gz.mtime = 0
        bytes = 0
        sent = 0
        over_cap = 0
        over_cap_bytes = 0
        records.each do |record|
          json = JSON.generate(record)
          size = json.bytesize + 1
          if bytes + size > @batch_bytes
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
        body = io.string.b
        Encoded.new(body: body, sha256: Digest::SHA256.hexdigest(body), sent: sent, over_cap: over_cap,
                    over_cap_bytes: over_cap_bytes, uncompressed_bytes: bytes)
      end
    end
  end
end
