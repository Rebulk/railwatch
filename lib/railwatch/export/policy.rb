# frozen_string_literal: true

require "securerandom"
require "digest"

module Railwatch
  module Export
    # What of a batch gets mirrored, and how it is packaged.
    #
    # There is one policy today and it sends everything: the same records, in
    # the same order, that the very same install would have sent had it been
    # configured for the cloud instead. That is deliberate. It means the
    # receiver's charts, thresholds and issue counts are exactly as correct as
    # they are for a cloud-only customer, and it means enabling mirroring
    # discloses nothing that choosing the cloud would not have.
    #
    # A future selective policy returns fewer, smaller selections from the same
    # method; nothing else in the queue needs to know.
    module Policy
      class Unsupported < StandardError; end

      # One thing to send: immutable once built.
      Selection = Struct.new(:key, :body, :body_sha256, :metadata, :record_count, :ndjson_bytes,
                             :dropped, keyword_init: true) do
        def metadata_sha256
          @metadata_sha256 ||= Digest::SHA256.hexdigest(JSON.generate(metadata.sort.to_h))
        end
      end

      module_function

      def fetch(name)
        raise Unsupported, "unknown export policy #{name}" unless name.to_s == "everything"

        Everything
      end

      module Everything
        VERSION = "everything-v1"

        module_function

        # `records` is the batch as it arrived, before mapping: mapping is
        # lossy and drops records this receiver may accept, so mirroring what
        # we stored would not be mirroring what we were sent.
        # The receiver refuses a request carrying more than this, whole. A
        # delivery it will always reject is not worth storing: leave the
        # excess out here, where it is counted as dropped, rather than
        # discovering it after a round trip that destroys the lot.
        MAX_RECORDS = 20_000

        def prepare(records:, encoder:, source_batch_id:, metadata: {})
          return [] if records.empty?

          over_count = [ records.size - MAX_RECORDS, 0 ].max
          encoded = encoder.encode(records.first(MAX_RECORDS))
          # Records the encoder left out are lost to the receiver as surely as
          # ones the client dropped, and the existing HTTP path reports them
          # together. Adding, not replacing: a batch that dropped 7 and
          # overflowed 2 lost 9.
          dropped = metadata.fetch("dropped", 0).to_i + encoded.over_cap + over_count
          dropped_bytes = metadata.fetch("dropped_bytes", 0).to_i + encoded.over_cap_bytes
          wire = metadata.merge("policy" => VERSION, "version" => Railwatch::VERSION,
                                "dropped" => dropped, "dropped_bytes" => dropped_bytes)
          # Nothing fitted. There is no body to send, but the loss is real and
          # has to be reported rather than filed as "nothing to do".
          return [ Selection.new(key: nil, record_count: 0, dropped: encoded.over_cap, metadata: wire) ] if encoded.sent.zero?

          [ Selection.new(
            key: "batch:#{source_batch_id}:#{VERSION}",
            body: encoded.body, body_sha256: encoded.sha256,
            record_count: encoded.sent, ndjson_bytes: encoded.uncompressed_bytes,
            dropped: encoded.over_cap, metadata: wire
          ) ]
        end
      end
    end
  end
end
