# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Ingest::Mapper do
  it "keeps mapping when another thread resets the schema cache after its lookup" do
    rec = { "v" => 1, "t" => "log", "timestamp" => Time.utc(2026, 9, 16, 14, 20).to_f,
            "level" => "info", "message" => "still mapped", "tags" => [ "widgets" ], "context" => "{}" }
    expected = described_class.row_for(rec, trusted: true)
    cache = described_class.const_get(:COLUMN_CACHE)
    reset = false
    allow(cache).to receive(:[]).and_wrap_original do |lookup, klass|
      lookup.call(klass).tap do |entry|
        if entry && !reset
          reset = true
          Thread.new { described_class.reset_schema_cache! }.value
        end
      end
    end

    expect(described_class.row_for(rec, trusted: true)).to eq(expected)
    expect(reset).to be(true)
    expect(described_class.row_for(rec, trusted: true)).to eq(expected)
  ensure
    described_class.reset_schema_cache!
  end
end
