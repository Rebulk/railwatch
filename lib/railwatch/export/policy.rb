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
                             keyword_init: true) do
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
        def prepare(records:, encoder:, source_batch_id:, metadata: {})
          return [] if records.empty?

          encoded = encoder.encode(records)
          return [] if encoded.sent.zero?

          [ Selection.new(
            key: "batch:#{source_batch_id}:#{VERSION}",
            body: encoded.body, body_sha256: encoded.sha256,
            record_count: encoded.sent, ndjson_bytes: encoded.uncompressed_bytes,
            metadata: metadata.merge("policy" => VERSION, "version" => Railwatch::VERSION,
                                     "dropped" => encoded.over_cap,
                                     "dropped_bytes" => encoded.over_cap_bytes)
          ) ]
        end
      end
    end
  end
end
