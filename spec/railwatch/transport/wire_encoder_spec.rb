# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Transport::WireEncoder do
  def decode(body) = Zlib::GzipReader.new(StringIO.new(body)).read

  let(:encoder) { described_class.new(batch_bytes: 8 * 1024 * 1024) }
  let(:records) { [ { "t" => "request", "route" => "/widgets" }, { "t" => "log", "message" => "héllo" } ] }

  it "writes one JSON line per record, in order" do
    encoded = encoder.encode(records)

    expect(decode(encoded.body).lines.map(&:chomp)).to eq(records.map { |r| JSON.generate(r) })
    expect(encoded.sent).to eq(2)
  end

  it "produces the same bytes for the same records, so a delivery keeps its identity" do
    # Gzip stores an mtime by default, which would make every encode of the
    # same batch a different delivery.
    first = encoder.encode(records)
    second = encoder.encode(records)

    expect(first.body).to eq(second.body)
    expect(first.sha256).to eq(second.sha256)
  end

  it "digests the compressed bytes that actually go on the wire" do
    encoded = encoder.encode(records)
    expect(encoded.sha256).to eq(Digest::SHA256.hexdigest(encoded.body))
  end

  it "leaves out records past the cap and reports them rather than growing the request" do
    small = described_class.new(batch_bytes: 60)
    encoded = small.encode([ { "t" => "a", "pad" => "x" * 10 }, { "t" => "b", "pad" => "y" * 200 } ])

    expect(encoded.sent).to eq(1)
    expect(encoded.over_cap).to eq(1)
    expect(encoded.over_cap_bytes).to be > 200
    expect(decode(encoded.body).lines.size).to eq(1)
  end

  it "keeps taking records that still fit after one was left out" do
    small = described_class.new(batch_bytes: 80)
    encoded = small.encode([ { "a" => "x" * 100 }, { "b" => 1 } ])

    expect(encoded.sent).to eq(1)
    expect(encoded.over_cap).to eq(1)
    expect(decode(encoded.body)).to include('"b"')
  end

  it "encodes an empty batch without raising" do
    encoded = encoder.encode([])
    expect(encoded.sent).to eq(0)
    expect(decode(encoded.body)).to eq("")
  end

  it "returns a binary body, so a length prefix can be concatenated to it" do
    expect(encoder.encode(records).body.encoding).to eq(Encoding::BINARY)
  end
end
