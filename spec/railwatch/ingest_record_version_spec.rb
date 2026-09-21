# frozen_string_literal: true

require "spec_helper"

# A record names its shape by type and version. The mapper only knows the
# versions this gem emits; anything else is refused by name, never read
# through columns that may no longer mean the same thing.
RSpec.describe "ingest record version" do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  let(:environment) { Railwatch::Environment.current }
  let(:now) { Time.utc(2026, 9, 20, 12, 0, 0) }

  def wire(type, v: Railwatch::Record::VERSIONS.fetch(type), **fields)
    { "v" => v, "t" => type.to_s, "timestamp" => now.to_f, "deploy" => "d1", "server" => "web-1",
      "_group" => Digest::MD5.hexdigest(type.to_s), "execution_source" => "command",
      "execution_id" => SecureRandom.uuid, "level" => "info", "message" => "hi" }.merge(fields.transform_keys(&:to_s))
  end

  # The embedded batch is the gem's own receiver; the untrusted path is what
  # Railwatch Cloud calls, checked through the mapper it calls.
  def write(records)
    travel_to(now) { Railwatch::Ingest::Batch.new(environment, records, embedded: true).write! }
  end

  it "accepts the version this gem emits" do
    result = write([ wire(:log) ])
    expect(result.rejected).to eq(0), result.rejections.inspect
    expect(Railwatch::Ingest::Mapper.row_for(wire(:log))).to be_present
  end

  it "rejects a trusted record at another version, by name, and keeps the rest of the batch" do
    result = write([ wire(:log, v: 2), wire(:log) ])
    expect(result.accepted).to eq(1)
    expect(result.rejections.sole).to include(type: "log", reason: a_string_including("log v2 is not v1"))
  end

  it "rejects an untrusted record at another version before reading any field" do
    expect { Railwatch::Ingest::Mapper.validate_record!(wire(:log, v: 2)) }.to raise_error(TypeError, "log v2 is not v1")
    expect { Railwatch::Ingest::Mapper.validate_record!(wire(:log, v: nil)) }.to raise_error(TypeError, "log vnil is not v1")
  end

  it "still reports an unknown type as unknown, not as a version mismatch" do
    result = write([ wire(:log, t: "widget") ])
    expect(result.rejections.sole).to include(reason: "unknown type")
  end
end
