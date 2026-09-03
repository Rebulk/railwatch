# frozen_string_literal: true

require "spec_helper"

RSpec.describe "job_attempt record" do
  it "reports status processed with job_id, attempt, name, queue, adapter/connection, duration, db_runtime, and counters for a clean perform" do
    WidgetJob.perform_now("bob")

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:status]).to eq("processed")
    expect(attempt[:job_id]).to be_a(String)
    expect(attempt[:provider_job_id]).to be_nil # ActiveJob::QueueAdapters::TestAdapter never assigns one
    expect(attempt[:attempt_id]).to be_a(String)
    expect(attempt[:attempt]).to eq(1)
    expect(attempt[:name]).to eq("WidgetJob")
    expect(attempt[:queue]).to eq("default")
    expect(attempt[:adapter]).to eq("Test")
    expect(attempt[:connection]).to eq("Test")
    expect(attempt[:priority]).to be_nil
    expect(attempt[:duration]).to be_a(Integer).and be >= 0
    expect(attempt[:db_runtime]).to be_a(Float).and be >= 0
    expect(attempt[:stages].keys).to eq([ "action" ])
    expect(attempt[:stages]["action"]).to be_a(Integer).and be >= 0
    expect(attempt[:counters][:queries]).to eq(1) # the Widget.where(...).to_a lookup
    expect(attempt[:arguments_preview]).to eq([ "String" ])
    expect(attempt[:concurrency_key]).to be_nil
  end

  it "reports status failed with an exception_preview when the job raises" do
    expect { WidgetJob.perform_now("bob", fail: true) }.to raise_error(RuntimeError)

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:status]).to eq("failed")
    expect(attempt[:exception_preview]).to eq("RuntimeError: widget job failed: bob")
    expect(attempt[:counters][:exceptions]).to eq(1)
  end

  it "reports status released, a populated queue_latency, and arguments_preview [] when retry_on schedules another attempt" do
    FlakyJob.perform_later
    perform_enqueued_jobs

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:status]).to eq("released")
    expect(attempt[:name]).to eq("FlakyJob")
    expect(attempt[:queue_latency]).to be_a(Integer).and be >= 0
    expect(attempt[:arguments_preview]).to eq([])
  end

  it "reports status aborted when a before_perform callback halts with throw :abort" do
    AbortedJob.perform_now

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:status]).to eq("aborted")
    expect(attempt[:name]).to eq("AbortedJob")
  end

  it "captures the concurrency_key computed from limits_concurrency" do
    ConcurrentJob.perform_now

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:concurrency_key]).to eq("ConcurrentJob/widget")
  end
end
