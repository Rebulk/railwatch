# frozen_string_literal: true

require "spec_helper"

# "Unpriced" tells the reader that the spend total is missing calls the
# registry could not price. A call that failed before the provider answered
# used no tokens and has nothing to price, so counting it made every model
# with any failure read "+N unpriced" even when every answered call was
# priced. Both paths that build the hour's rollup must agree.
RSpec.describe "LLM calls counted as unpriced" do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  let(:environment) { Railwatch::Environment.current }
  let(:now) { Time.utc(2026, 9, 16, 14, 20, 0) }
  let(:bucket) { Time.utc(2026, 9, 16, 14) }
  let(:group) { Digest::MD5.hexdigest("claude-opus-5 chat") }

  def llm_call(status:, cost_nanos:)
    Railwatch.wire_fixtures.fetch("llm_call").merge(
      "timestamp" => now.to_f, "_group" => group, "trace_id" => SecureRandom.uuid,
      "execution_id" => SecureRandom.uuid, "status" => status, "cost_nanos" => cost_nanos
    )
  end

  let(:records) do
    [ llm_call(status: "ok", cost_nanos: 100_000),
      llm_call(status: "ok", cost_nanos: nil),
      llm_call(status: "failed", cost_nanos: nil) ]
  end

  def extra
    environment.with_telemetry do
      Railwatch::Telemetry::Rollup.find_by(record_type: "llm_call", group_hash: group, bucket: bucket).extra
    end
  end

  it "counts only answered calls with no price, as the batch lands" do
    travel_to(now) { Railwatch::Ingest::Batch.new(environment, records, embedded: true).write! }

    expect(extra).to include("priced" => 1, "unpriced" => 1)
  end

  it "counts only answered calls with no price when RollupJob recomputes the hour" do
    travel_to(now) { Railwatch::Ingest::Batch.new(environment, records, embedded: true).write! }
    travel_to(now) { Railwatch::RollupJob.perform_now(environment, bucket) }

    expect(extra).to include("priced" => 1, "unpriced" => 1)
  end
end
