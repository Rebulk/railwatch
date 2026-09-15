# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Subscribers::Jobs do
  around do |example|
    Railwatch.config.capture_job_retry_errors = false
    example.run
  ensure
    Railwatch.config.capture_job_retry_errors = false
  end

  it "keeps the retry log but does not capture the retry error by default" do
    FlakyJob.perform_later
    perform_enqueued_jobs

    expect(railwatch_records(:exception)).to be_empty
    retry_log = railwatch_records(:log).find { |log| log[:tags] == [ "active_job", "retry" ] }
    expect(retry_log[:message]).to eq("Retrying FlakyJob in 0.0s: RuntimeError")
  end

  it "captures a retry error as a handled warning on the current job attempt" do
    Railwatch.config.capture_job_retry_errors = true

    FlakyJob.perform_later
    perform_enqueued_jobs

    attempt = railwatch_records(:job_attempt).sole
    exception = railwatch_records(:exception).sole
    expect(exception).to include(
      handled: true,
      severity: "warning",
      source: "application.active_job.enqueue_retry",
      execution_id: attempt[:execution_id]
    )
    expect(JSON.parse(exception[:context])).to include("attempt" => 1, "wait" => 0.0)
  end

  it "captures the retry once and the exhausted retry once, with their respective dispositions" do
    Railwatch.config.capture_job_retry_errors = true

    FlakyJob.perform_later
    perform_enqueued_jobs
    expect { perform_enqueued_jobs(at: 1.second.from_now) }.to raise_error(RuntimeError, "flaky")

    attempts = railwatch_records(:job_attempt)
    exceptions = railwatch_records(:exception)
    expect(attempts.map { |attempt| attempt[:status] }).to contain_exactly("released", "failed")
    expect(exceptions.map { |exception| [ exception[:handled], exception[:source] ] }).to contain_exactly(
      [ true, "application.active_job.enqueue_retry" ],
      [ false, "application.active_job.retry_stopped" ]
    )
    expect(exceptions.map { |exception| exception[:execution_id] }).to match_array(attempts.map { |attempt| attempt[:execution_id] })
  end

  it "reports a failed job's error once when the queue backend reports it again after the attempt" do
    WidgetJob.perform_later("dup", fail: true)
    # Solid Queue re-raises the error out of ClaimedExecution#perform and its
    # thread's app executor reports it to Rails.error with no execution
    # current any more.
    expect { perform_enqueued_jobs }.to raise_error(RuntimeError) do |error|
      Railwatch::Current.clear
      Rails.error.report(error, handled: false, source: "application.solid_queue")
    end

    attempt = railwatch_records(:job_attempt).sole
    exception = railwatch_records(:exception).sole
    expect(exception).to include(source: "application.active_job", execution_id: attempt[:execution_id])
  end

  it "still records an explicit handled report of an error that was already reported unhandled" do
    error = RuntimeError.new("seen")
    Railwatch::Subscribers::Exceptions.capture(error, handled: false, severity: :error, source: "test")
    Railwatch.report(error, handled: true)

    expect(railwatch_records(:exception).map { |e| e[:handled] }).to eq([ false, true ])
  end
end
