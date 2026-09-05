# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::RequestPayload do
  it "preserves ordinary JSON values without reporting truncation" do
    result = described_class.normalize({ "name" => "Ada", "count" => 3, "ok" => true, "nil" => nil })

    expect(result.value).to eq({ "name" => "Ada", "count" => 3, "ok" => true, "nil" => nil })
    expect(result.truncated).to be(false)
    expect(result.failed).to be(false)
  end

  it "enforces the exact encoded byte limit even for escaped strings" do
    result = described_class.normalize({ "items" => Array.new(1_000) { "\u0000" * 1_000 } })

    expect(result.truncated).to be(true)
    expect(result.failed).to be(false)
    expect(JSON.generate(result.value).bytesize).to be <= described_class::MAX_BYTES
  end

  it "bounds nodes, depth, scalar strings, and huge integers truthfully" do
    deep = { "number" => 2**100_000, "long" => "x" * (described_class::MAX_STRING_BYTES + 1) }
    cursor = deep
    (described_class::MAX_DEPTH + 10).times do
      cursor["next"] = {}
      cursor = cursor["next"]
    end
    deep["many"] = Array.new(described_class::MAX_NODES + 100, "x")

    result = described_class.normalize(deep)

    expect(result.truncated).to be(true)
    expect(result.failed).to be(false)
    expect(JSON.generate(result.value).bytesize).to be <= described_class::MAX_BYTES
    expect(result.value["number"]).to eq("[INTEGER TOO LARGE]")
    expect(result.value["long"].bytesize).to eq(described_class::MAX_STRING_BYTES)
  end

  it "fails closed on cycles rather than retaining a cyclic payload" do
    cycle = {}
    cycle["self"] = cycle

    result = described_class.normalize(cycle)

    expect(result.value).to be_a(Hash)
    expect(result.truncated).to be(true)
    expect(result.failed).to be(true)
  end

  it "normalizes invalid strings and unsupported objects without invoking to_json" do
    object = Object.new
    object.define_singleton_method(:to_json) { raise "must not run" }
    result = described_class.normalize({ "invalid" => "\xFF".b, "object" => object })

    expect(result.value["invalid"]).to be_valid_encoding
    expect(result.value["object"]).to eq("[Object]")
    expect(result.truncated).to be(true)
    expect { JSON.generate(result.value) }.not_to raise_error
  end

  it "reports invalid-byte replacement as truncation" do
    result = described_class.normalize({ "invalid" => "\xFF".b })

    expect(result.value["invalid"]).to eq("\uFFFD")
    expect(result.truncated).to be(true)
    expect(result.failed).to be(false)
  end

  it "bounds a huge source string before copying or transcoding it" do
    result = described_class.normalize({ "huge" => "x" * 1_000_000 })

    expect(result.value["huge"].bytesize).to eq(described_class::MAX_STRING_BYTES)
    expect(result.truncated).to be(true)
    expect(JSON.generate(result.value).bytesize).to be <= described_class::MAX_BYTES
  end

  it "fails closed when truncating a key that could hide a sensitive suffix" do
    key = ("x" * described_class::MAX_KEY_BYTES) + "password"

    result = described_class.normalize({ key => "must not leak" })

    expect(result.value.values).to eq([ Lantern::Redactor::FILTERED ])
    expect(result.truncated).to be(true)
  end

  it "bounds traversal even when many distinct keys normalize to one key" do
    value = (0...(described_class::MAX_NODES + 100)).to_h do |index|
      [ ("x" * described_class::MAX_KEY_BYTES) + index.to_s, "secret" ]
    end

    result = described_class.normalize(value)

    expect(result.value.size).to eq(1)
    expect(result.truncated).to be(true)
    expect(JSON.generate(result.value).bytesize).to be <= described_class::MAX_BYTES
  end
end
