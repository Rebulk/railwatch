# frozen_string_literal: true

require "spec_helper"

# In-process ingest folds each batch into the hourly rollups as it lands,
# so the dashboard's counts and percentiles move with every batch rather
# than once a minute when RollupJob recomputes the hour.
RSpec.describe Railwatch::Ingest::RollupAbsorber do
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

  def wire(type, **fields)
    {
      "v" => 1, "t" => type.to_s, "timestamp" => now.to_f, "deploy" => "d1", "server" => "web-1",
      "_group" => Digest::MD5.hexdigest(fields.delete(:group) || type.to_s), "trace_id" => SecureRandom.uuid,
      "execution_source" => "request", "execution_id" => SecureRandom.uuid, "execution_preview" => "WidgetsController#index",
      "execution_stage" => "action", "user" => nil, "tenant" => nil
    }.merge(fields.transform_keys(&:to_s))
  end

  def request(duration:, status: 200, group: "GET /widgets")
    wire(:request, group: group, method: "GET", route: "/widgets(.:format)", controller: "widgets", action: "index",
         status_code: status, duration: duration, stages: { "action" => duration }, counters: { "queries" => 1 },
         url: "http://x/widgets", path: "/widgets", ip: "127.0.0.1", headers: {}, context: "{}", user_agent: "rspec")
  end

  def write!(records)
    result = travel_to(now) { Railwatch::Ingest::Batch.new(environment, records, embedded: true).write! }
    expect(result.rejected).to eq(0), result.rejections.inspect
    result
  end

  def rollup(type, group)
    environment.with_telemetry do
      Railwatch::Telemetry::Rollup.find_by(record_type: type, group_hash: Digest::MD5.hexdigest(group), bucket: bucket)
    end
  end

  it "creates the hour's rollup row for a group from the first batch, counts and percentiles included" do
    write!([ request(duration: 1_000), request(duration: 3_000), request(duration: 5_000, status: 503) ])

    row = rollup("request", "GET /widgets")
    expect(row).to have_attributes(name: "GET /widgets(.:format)", count: 3, error_count: 1, client_error_count: 0,
                                   duration_sum: 9_000, duration_max: 5_000)
    expect(row.p50).to be_within(1).of(3_000)
  end

  it "merges the next batch into the same row instead of replacing it, so the counter climbs batch by batch" do
    write!([ request(duration: 1_000) ])
    write!([ request(duration: 9_000, status: 404), request(duration: 9_000, status: 404) ])

    row = rollup("request", "GET /widgets")
    expect(row.count).to eq(3)
    expect(row.client_error_count).to eq(2)
    expect(row.duration_sum).to eq(19_000)
    expect(row.duration_max).to eq(9_000)
    expect(row.p99).to be_within(1).of(9_000)
    expect(environment.with_telemetry { Railwatch::Telemetry::Rollup.where(record_type: "request").count }).to eq(1)
  end

  it "does not enqueue the per-batch recompute in embedded mode" do
    expect { write!([ request(duration: 1_000) ]) }.not_to have_enqueued_job(Railwatch::RollupJob)
  end

  it "names a query group from its shape when the row's text moved there" do
    sql = "SELECT widgets.* FROM widgets WHERE id = ?"
    group = Railwatch::Record.group_hash("primary", sql)
    write!([ wire(:query, sql: sql, duration: 250, connection: "primary", adapter: "sqlite", role: "writing",
                  async: false, in_transaction: false, row_count: 1, source: "app/x.rb:1", allocations: 10).merge("_group" => group) ])

    row = environment.with_telemetry { Railwatch::Telemetry::Rollup.find_by(record_type: "query", group_hash: group) }
    expect(row.name).to eq(sql)
    expect(row.count).to eq(1)
  end

  it "agrees with RollupJob's full recompute for the same hour" do
    write!([ request(duration: 1_000), request(duration: 2_000, status: 500), request(duration: 4_000, status: 422) ])
    incremental = rollup("request", "GET /widgets").attributes.except("id", "digest")

    travel_to(now) { Railwatch::RollupJob.perform_now(environment, bucket) }
    recomputed = rollup("request", "GET /widgets").attributes.except("id", "digest")

    expect(recomputed).to eq(incremental)
  end
end
