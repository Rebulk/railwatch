# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::Subscribers::Jobs do
  around do |example|
    Lantern.config.capture_job_retry_errors = false
    example.run
  ensure
    Lantern.config.capture_job_retry_errors = false
  end

  it "keeps the retry log but does not capture the retry error by default" do
    FlakyJob.perform_later
    perform_enqueued_jobs

    expect(lantern_records(:exception)).to be_empty
    retry_log = lantern_records(:log).find { |log| log[:tags] == [ "active_job", "retry" ] }
    expect(retry_log[:message]).to eq("Retrying FlakyJob in 0.0s: RuntimeError")
  end

  it "captures a retry error as a handled warning on the current job attempt" do
    Lantern.config.capture_job_retry_errors = true

    FlakyJob.perform_later
    perform_enqueued_jobs

    attempt = lantern_records(:job_attempt).sole
    exception = lantern_records(:exception).sole
    expect(exception).to include(
      handled: true,
      severity: "warning",
      source: "application.active_job.enqueue_retry",
      execution_id: attempt[:execution_id]
    )
    expect(JSON.parse(exception[:context])).to include("attempt" => 1, "wait" => 0.0)
  end

  it "captures the retry once and the exhausted retry once, with their respective dispositions" do
    Lantern.config.capture_job_retry_errors = true

    FlakyJob.perform_later
    perform_enqueued_jobs
    expect { perform_enqueued_jobs(at: 1.second.from_now) }.to raise_error(RuntimeError, "flaky")

    attempts = lantern_records(:job_attempt)
    exceptions = lantern_records(:exception)
    expect(attempts.map { |attempt| attempt[:status] }).to contain_exactly("released", "failed")
    expect(exceptions.map { |exception| [ exception[:handled], exception[:source] ] }).to contain_exactly(
      [ true, "application.active_job.enqueue_retry" ],
      [ false, "application.active_job.retry_stopped" ]
    )
    expect(exceptions.map { |exception| exception[:execution_id] }).to match_array(attempts.map { |attempt| attempt[:execution_id] })
  end
end
