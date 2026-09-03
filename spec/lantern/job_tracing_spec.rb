# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::JobTracing, type: :request do
  it "round-trips lantern_trace_id and lantern_parent_id through serialize/deserialize" do
    job = WidgetJob.new("hello")
    job.lantern_trace_id = "trace-abc"
    job.lantern_parent_id = "parent-xyz"

    data = job.serialize
    expect(data["lantern_trace_id"]).to eq("trace-abc")
    expect(data["lantern_parent_id"]).to eq("parent-xyz")

    loaded = WidgetJob.new
    loaded.deserialize(data)
    expect(loaded.lantern_trace_id).to eq("trace-abc")
    expect(loaded.lantern_parent_id).to eq("parent-xyz")
  end

  it "falls back to the current execution's trace_id/id when not explicitly set" do
    exe = Lantern.start_execution(source: :command, sample_kind: :commands)
    job = WidgetJob.new("hello")

    data = job.serialize

    expect(data["lantern_trace_id"]).to eq(exe.trace_id)
    expect(data["lantern_parent_id"]).to eq(exe.id)
  ensure
    Lantern.finish_execution
  end

  it "links a job attempt's trace_id back to the request that enqueued it" do
    # Enqueue during the request, then drain the queue afterwards -- draining
    # *during* the request (perform_enqueued_jobs { get ... }) performs the
    # job inline while the request's execution is still Current, which the
    # perform.active_job subscriber's un-scoped `Current.execution = exe`
    # then clobbers, so the request never gets a Current execution to finish
    # against. That's a separate concern from what this example is testing.
    get "/enqueue"
    req = lantern_records(:request).sole

    perform_enqueued_jobs

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:trace_id]).to eq(req[:trace_id])
  end

  it "surfaces the enqueuing execution's id as parent_id on the shipped job_attempt record" do
    get "/enqueue"
    req = lantern_records(:request).sole

    perform_enqueued_jobs

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:parent_id]).to eq(req[:execution_id])
  end

  it "gives a job enqueued outside any execution a fresh trace_id of its own" do
    perform_enqueued_jobs { WidgetJob.perform_later("standalone") }

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:trace_id]).to be_a(String)
    expect(attempt[:trace_id]).not_to be_empty
  end
end
