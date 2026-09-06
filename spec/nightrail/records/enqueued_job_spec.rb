# frozen_string_literal: true

require "spec_helper"

RSpec.describe "enqueued_job record" do
  def finish!
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "captures job_id, name, queue, adapter, scheduled_at, duration, and failed false for a plain enqueue" do
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    WidgetJob.perform_later("bob")
    finish!

    job = nightrail_records(:enqueued_job).sole
    expect(job[:job_id]).to be_a(String)
    expect(job[:name]).to eq("WidgetJob")
    expect(job[:queue]).to eq("default")
    expect(job[:adapter]).to eq("Test")
    expect(job[:scheduled_at]).to be_nil
    expect(job[:duration]).to be_a(Integer).and be >= 0
    expect(job[:failed]).to be(false)
  end

  it "captures scheduled_at for a job enqueued via enqueue_at" do
    run_at = 1.hour.from_now
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    WidgetJob.set(wait_until: run_at).perform_later("bob")
    finish!

    job = nightrail_records(:enqueued_job).sole
    expect(job[:scheduled_at]).to be_within(1).of(run_at.to_f)
  end

  it "reports one enqueued_job record per job for a batch enqueued via enqueue_all" do
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    ActiveJob.perform_all_later([ WidgetJob.new("a"), WidgetJob.new("b") ])
    finish!

    jobs = nightrail_records(:enqueued_job)
    expect(jobs.size).to eq(2)
    expect(jobs.map { |j| j[:name] }).to eq(%w[WidgetJob WidgetJob])
  end

  it "reports failed true when the adapter raises while enqueuing" do
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    allow_any_instance_of(ActiveJob::QueueAdapters::TestAdapter).to receive(:enqueue).and_raise("boom")
    expect { WidgetJob.perform_later("bob") }.to raise_error("boom")
    finish!

    job = nightrail_records(:enqueued_job).sole
    expect(job[:failed]).to be(true)
  end
end
