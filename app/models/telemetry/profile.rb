# frozen_string_literal: true

module Telemetry
  # A sampled stack profile of one execution. `stacks` is gzip of collapsed
  # stacks ("outer;inner;leaf count\n"), the format flamegraph tools read.
  class Profile < TelemetryRecord
    include Child

    # Railwatch's profiler caps collapsed stacks at 4 MiB before compression.
    # Enforce the same contract here even when a client lies about its size.
    MAX_INGEST_BYTES = 4.megabytes

    # A minute of wall profiling can decompress to tens of megabytes; the
    # page only ever renders a flamegraph, so the payload is cut here rather
    # than shipped whole to the browser.
    MAX_COLLAPSED_BYTES = 2.megabytes

    def collapsed
      BoundedGzip.utf8!(BoundedGzip.decompress(stacks, max_bytes: MAX_INGEST_BYTES))
    end

    # [text, truncated?] - cut on a line boundary so the parser never sees
    # half a stack line.
    def collapsed_capped(limit = MAX_COLLAPSED_BYTES)
      text, truncated = BoundedGzip.decompress_capped(stacks, limit: [limit, MAX_INGEST_BYTES].min)
      text = text.sub(/[^\n]*\z/, "") if truncated

      [BoundedGzip.utf8!(text), truncated]
    end

    def timeline_label
      "#{profiler} profile (#{samples} samples)"
    end
  end
end
