# frozen_string_literal: true

require "spec_helper"

# RollupJob reads an hour's raw rows outside its write transaction. In an
# embedded install a batch can land, and be folded into the rollups by the
# absorber, between that read and the write; the write must not replace the
# absorbed row with a snapshot that predates the batch.
RSpec.describe Railwatch::RollupJob, "reconciling an hour the absorber is also writing" do
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
  let(:group) { Digest::MD5.hexdigest("GET /widgets") }

  def request(duration:)
    {
      "v" => 1, "t" => "request", "timestamp" => now.to_f, "deploy" => "d1", "server" => "web-1",
      "_group" => group, "trace_id" => SecureRandom.uuid, "execution_source" => "request",
      "execution_id" => SecureRandom.uuid, "execution_preview" => "WidgetsController#index", "execution_stage" => "action",
      "user" => nil, "tenant" => nil, "method" => "GET", "route" => "/widgets(.:format)", "controller" => "widgets",
      "action" => "index", "status_code" => 200, "duration" => duration, "stages" => { "action" => duration },
      "counters" => { "queries" => 1 }, "url" => "http://x/widgets", "path" => "/widgets", "ip" => "127.0.0.1",
      "headers" => {}, "context" => "{}", "user_agent" => "rspec"
    }
  end

  def write!(records)
    travel_to(now) { write_now!(records) }
  end

  # For use inside a block that is already travelling to `now`.
  def write_now!(records)
    Railwatch::Ingest::Batch.new(environment, records, embedded: true).write!
  end

  def rollup
    environment.with_telemetry { Railwatch::Telemetry::Rollup.find_by(record_type: "request", group_hash: group, bucket: bucket) }
  end

  it "keeps the absorbed row when a batch landed after the recompute read the hour" do
    write!([ request(duration: 1_000) ])

    # The race: the job has read the hour (one request) and is about to open
    # its write transaction when a second batch lands and is absorbed.
    raced = false
    allow(Railwatch::Telemetry::Rollup).to receive(:transaction).and_wrap_original do |original, *args, &block|
      unless raced
        raced = true
        write_now!([ request(duration: 5_000) ])
      end
      original.call(*args, &block)
    end

    travel_to(now) { described_class.new.perform(environment, bucket) }
    expect(raced).to be(true)

    expect(rollup.count).to eq(2)
    expect(rollup.duration_max).to eq(5_000)
  end

  it "still replaces a row when the recompute has at least as many rows as were absorbed" do
    write!([ request(duration: 1_000), request(duration: 3_000) ])
    environment.with_telemetry { Railwatch::Telemetry::Rollup.where(group_hash: group).update_all(count: 1, duration_max: 1) }

    travel_to(now) { described_class.new.perform(environment, bucket) }

    expect(rollup).to have_attributes(count: 2, duration_max: 3_000)
  end
end
