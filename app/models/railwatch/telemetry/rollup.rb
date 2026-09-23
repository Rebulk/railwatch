# frozen_string_literal: true

module Railwatch
  require "tdigest"

  module Telemetry
    # Hourly aggregate per (record_type, group). Percentiles are exact within
    # an hour and merged across hours with t-digest, so a 30-day p95 for a
    # route is one query over 720 small rows.
    class Rollup < TelemetryRecord
      scope :for_type, ->(type) { where(record_type: type) }
      scope :between, ->(from, to) { where(bucket: from.beginning_of_hour..to) }

      def self.bucket_for(time)
        time.utc.beginning_of_hour
      end

      # Merge a list of duration samples (microseconds) into the bucket.
      def self.absorb!(record_type:, group_hash:, name:, bucket:, durations:, errors: 0, client_errors: 0, extra: {})
        return if durations.empty?
        row = find_or_initialize_by(record_type: record_type, group_hash: group_hash, bucket: bucket)
        row.name = name
        digest = row.digest ? TDigest::TDigest.from_bytes(row.digest) : TDigest::TDigest.new(0.01)
        durations.each { |d| digest.push(d) }
        digest.compress!
        row.count += durations.size
        row.error_count += errors
        row.client_error_count += client_errors
        row.duration_sum += durations.sum
        row.duration_max = [ row.duration_max, durations.max ].max
        row.p50 = digest.percentile(0.5).to_i
        row.p95 = digest.percentile(0.95).to_i
        row.p99 = digest.percentile(0.99).to_i
        row.digest = digest.as_small_bytes
        row.extra = row.extra.merge(extra) { |_k, a, b| a.is_a?(Numeric) && b.is_a?(Numeric) ? a + b : b }
        row.save!
        row
      end

      # The row absorb! would write over an empty bucket, as attributes for
      # insert_all. RollupJob deletes an hour's rows and writes every group in
      # one statement, so the read absorb! does per group is wasted there.
      def self.fresh_attributes(record_type:, group_hash:, name:, bucket:, durations:, errors: 0, client_errors: 0, extra: {})
        digest = TDigest::TDigest.new(0.01)
        durations.each { |d| digest.push(d) }
        digest.compress!
        { record_type: record_type, group_hash: group_hash, name: name, bucket: bucket,
         count: durations.size, error_count: errors, client_error_count: client_errors,
         duration_sum: durations.sum, duration_max: durations.max,
         p50: digest.percentile(0.5).to_i, p95: digest.percentile(0.95).to_i, p99: digest.percentile(0.99).to_i,
         digest: digest.as_small_bytes, extra: extra }
      end

      # Aggregate a relation of rollups into one summary with merged percentiles.
      def self.summarize(relation)
        rows = relation.to_a
        return { count: 0, errors: 0, client_errors: 0, avg: 0, p50: 0, p95: 0, p99: 0, max: 0, extra: {} } if rows.empty?
        p50, p95, p99 = merged_percentiles(rows, [ 0.5, 0.95, 0.99 ])
        count = rows.sum(&:count)
        {
          count: count,
          errors: rows.sum(&:error_count),
          client_errors: rows.sum(&:client_error_count),
          avg: count.zero? ? 0 : (rows.sum(&:duration_sum) / count),
          p50: p50,
          p95: p95,
          p99: p99,
          max: rows.map(&:duration_max).max,
          # Everything a type puts in `extra` -- llm_call's cost_nanos and
          # token counts, cache_event's hits and misses -- merged the way
          # absorb! merges it: numbers add up, anything else is last-wins.
          # Spend is a sum over a window rather than a percentile of
          # durations, so a rule about money has nowhere else to read from.
          extra: merge_extras(rows)
        }
      end

      # Percentiles of the union of every row's centroids, read straight out
      # of the stored bytes. Merging through TDigest pushed each centroid into
      # a red-black tree one at a time: 2.8 s for a week of the platform's
      # own query rollups (18,674 rows) and 7 s for thirty days, on every
      # cold page load. Sorting the centroids once and walking their
      # cumulative counts answers the same question without re-clustering:
      # 353 ms and 1 s for those two windows. The answer is the first
      # centroid whose running total reaches n * p, which is nearest rank --
      # the rule raw_series uses for sub-hour buckets, so both readings of a
      # window agree. (TDigest#percentile compares each centroid's midpoint
      # instead, which puts the median of 1,000 sevens and 300 nines at 9.)
      def self.merged_percentiles(rows, ps)
        means = []
        counts = []
        rows.each { |row| centroids(row.digest, means, counts) if row.digest }
        return ps.map { 0 } if means.empty?

        order = (0...means.size).sort_by { |i| means[i] }
        total = counts.sum
        targets = ps.map { |p| total * p }
        found = []
        seen = 0
        order.each do |i|
          seen += counts[i]
          found << means[i] while found.size < targets.size && seen >= targets[found.size]
          break if found.size == targets.size
        end
        found << means[order.last] while found.size < targets.size
        found.map(&:to_i)
      end

      # Appends one stored digest's centroid means and weights, in either of
      # the tdigest gem's encodings (TDigest.from_bytes reads the same two).
      def self.centroids(bytes, means, counts)
        format, _compression, size = bytes.unpack("LdL")
        case format
        when TDigest::TDigest::VERBOSE_ENCODING
          means.concat(bytes.unpack("@16d#{size}"))
          counts.concat(bytes.unpack("@#{16 + 8 * size}L#{size}"))
        when TDigest::TDigest::SMALL_ENCODING
          # Means are delta-encoded 4-byte floats; weights are 7-bit varints,
          # one byte each unless a centroid holds 128 or more samples.
          mean = 0.0
          bytes.unpack("@16f#{size}").each { |delta| means << (mean += delta) }
          weights = bytes.byteslice(16 + 4 * size, bytes.bytesize).unpack("C*")
          if weights.size == size
            counts.concat(weights)
          else
            at = 0
            size.times do
              byte = weights[at]
              at += 1
              weight = byte & 0x7f
              shift = 7
              while byte & 0x80 != 0
                byte = weights[at] || 0
                at += 1
                weight += (byte & 0x7f) << shift
                shift += 7
              end
              counts << weight
            end
          end
        else
          raise ArgumentError, "unknown t-digest encoding #{format}"
        end
      end
      private_class_method :centroids

      def self.merge_extras(rows)
        rows.each_with_object({}) do |row, out|
          row.extra.each do |key, value|
            existing = out[key]
            out[key] = existing.is_a?(Numeric) && value.is_a?(Numeric) ? existing + value : value
          end
        end
      end
    end
  end
end
