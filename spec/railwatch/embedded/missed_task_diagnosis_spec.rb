# frozen_string_literal: true

require "spec_helper"

# A missed scheduled task has three quite different causes, and Solid Queue's
# own tables tell them apart: the scheduler writes a RecurringExecution the
# moment it enqueues a run, and Process rows say whether a worker is alive.
RSpec.describe Railwatch::CheckScheduledTasksJob, "diagnosing a missed run" do
  include ActiveSupport::Testing::TimeHelpers

  before(:context) do
    schema_path = Gem.find_files("generators/solid_queue/install/templates/db/queue_schema.rb").first
    body = File.readlines(schema_path)[1..-2].join
    SolidQueue::Record.connection.instance_eval(body)
  end

  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  let(:environment) { Railwatch::Environment.current }
  let(:now) { Time.utc(2026, 9, 16, 14, 20, 0) }
  # Ran on the hour; every 5 minutes; so 14:05 was expected and 15 minutes is
  # well past the 5-minute grace.
  let(:last_run) { Time.utc(2026, 9, 16, 14, 0, 0) }

  def record_run(key, at)
    environment.with_telemetry do
      Railwatch::Telemetry::Execution.create!(
        occurred_at: at, kind: "scheduled_task", name: "NightlyJob", duration: 1_000, outcome: "processed",
        task_key: key, execution_id: SecureRandom.uuid, trace_id: SecureRandom.uuid, group_hash: Digest::MD5.hexdigest(key),
        detail: { "schedule" => "*/5 * * * *" })
    end
  end

  def missed_issue = Railwatch::Issue.find_by(group_hash: "missed:nightly")

  def check = travel_to(now) { described_class.new.perform(environment) }

  it "says the scheduler never enqueued the run when Solid Queue has no record of it" do
    record_run("nightly", last_run)

    check

    expect(missed_issue.title).to end_with(": the scheduler never enqueued it")
    expect(missed_issue.sample["cause"]).to eq("scheduler")
  end

  it "says the run was enqueued but no worker is running when Solid Queue enqueued it and has no worker process" do
    record_run("nightly", last_run)
    job = SolidQueue::Job.create!(queue_name: "default", class_name: "NightlyJob", active_job_id: SecureRandom.uuid, priority: 0)
    SolidQueue::RecurringExecution.create!(task_key: "nightly", run_at: Time.utc(2026, 9, 16, 14, 5), job_id: job.id)

    check

    expect(missed_issue.title).to end_with(": enqueued, but no Solid Queue worker is running")
    expect(missed_issue.sample).to include("cause" => "no_worker", "workers" => 0)
  end

  it "says the run is enqueued and waiting when a worker is alive but has not got to it" do
    record_run("nightly", last_run)
    job = SolidQueue::Job.create!(queue_name: "default", class_name: "NightlyJob", active_job_id: SecureRandom.uuid, priority: 0)
    SolidQueue::RecurringExecution.create!(task_key: "nightly", run_at: Time.utc(2026, 9, 16, 14, 5), job_id: job.id)
    SolidQueue::Process.create!(kind: "Worker", name: "worker-1", pid: 1, hostname: "web-1", last_heartbeat_at: now, metadata: {})

    check

    expect(missed_issue.title).to end_with(": enqueued, not yet performed")
    expect(missed_issue.sample).to include("cause" => "backlog", "workers" => 1)
  end

  it "does not open an issue for a task that ran on time" do
    record_run("nightly", now - 2.minutes)

    check

    expect(missed_issue).to be_nil
  end
end
