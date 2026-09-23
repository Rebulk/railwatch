# frozen_string_literal: true

require "spec_helper"

# Rollup.summarize merges hourly t-digests into one window's percentiles. It
# reads centroids straight out of the stored bytes instead of rebuilding a
# TDigest, which was seconds per page on a busy environment.
RSpec.describe Railwatch::Telemetry::Rollup, ".merged_percentiles" do
  Row = Struct.new(:digest)

  def digest(samples, encoding: :small)
    d = TDigest::TDigest.new(0.01)
    samples.each { |s| d.push(s) }
    d.compress!
    Row.new(encoding == :small ? d.as_small_bytes : d.as_bytes)
  end

  def nearest_rank(sorted, p) = sorted[(sorted.size * p).ceil - 1]

  it "stays within 2% of the exact nearest-rank p50 and p95 across many merged hours" do
    random = Random.new(42)
    hours = Array.new(24) { Array.new(random.rand(50..2_000)) { (random.rand**3 * 2_000_000).to_i + 1 } }
    all = hours.flatten.sort

    p50, p95 = described_class.merged_percentiles(hours.map { |h| digest(h) }, [ 0.5, 0.95 ])

    expect(p50).to be_within(nearest_rank(all, 0.5) * 0.02).of(nearest_rank(all, 0.5))
    expect(p95).to be_within(nearest_rank(all, 0.95) * 0.02).of(nearest_rank(all, 0.95))
  end

  it "is exact for a few distinct values, where a midpoint rule would round the median up" do
    heavy = digest([ 7 ] * 1_000 + [ 9 ] * 300)

    expect(described_class.merged_percentiles([ heavy ], [ 0.5, 0.95 ])).to eq([ 7, 9 ])
  end

  it "reads both of the tdigest gem's encodings, including multi-byte weights" do
    # 500 hundreds need a two-byte weight in the small encoding. Of 504
    # samples, rank 502 (p = 0.995) is the 300.
    samples = [ 100 ] * 500 + [ 200, 300, 400, 500 ]

    expect(described_class.merged_percentiles([ digest(samples, encoding: :small) ], [ 0.5, 0.995 ]))
      .to eq(described_class.merged_percentiles([ digest(samples, encoding: :verbose) ], [ 0.5, 0.995 ]))
      .and eq([ 100, 300 ])
  end

  it "answers zero when no row carries a digest" do
    expect(described_class.merged_percentiles([ Row.new(nil) ], [ 0.5 ])).to eq([ 0 ])
  end
end
