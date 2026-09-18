# frozen_string_literal: true

# The hosted platform bounds ingest request bodies with Rack middleware. In
# an embedded install nothing arrives over HTTP, but Ingest::Payload and
# Telemetry::Attachment still size their limits from this constant.
module Railwatch
  module IngestRequestBodyLimit
    MAX_BYTES = 32 * 1024 * 1024
  end
end
