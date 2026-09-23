# frozen_string_literal: true

require "spec_helper"

# A job's group is the digest of its class name and a scheduled task's the
# digest of its key, so lookups by class or key seek group_hash's index
# instead of walking every execution of the kind (49 s for a week through
# MCP's class: filter; 10 s for the scheduled tasks page's schedules).
RSpec.describe "Lookups that seek an execution's group" do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  before { Railwatch::Environment.current }

  let(:execution) { Railwatch::Telemetry::Execution }

  def run(kind, name, at:, task_key: nil, schedule: nil)
    execution.create!(kind: kind, name: name, group_hash: Railwatch::Record.group_hash(task_key || name), task_key: task_key,
      duration: 1_000, occurred_at: at, detail: schedule ? { "schedule" => schedule } : {})
  end

  it "filters jobs by class through the class's group" do
    billing = run("job_attempt", "BillingJob", at: 1.hour.ago)
    run("job_attempt", "MailerJob", at: 1.hour.ago)

    found = Railwatch::FilterQuery.apply(execution.jobs, resource: :jobs, query: "class:BillingJob", from: 1.day.ago, to: Time.current)
    expect(found).to contain_exactly(billing)
    expect(found.to_sql).to include(Railwatch::Record.group_hash("BillingJob"))
  end

  # Solid Queue's pruned attempts are named "(pruned)" but grouped under
  # SolidQueue::Pruned, so the class's own digest alone would miss them.
  it "finds a class whose group is not the digest of its name, through the rollups" do
    pruned = execution.create!(kind: "job_attempt", name: "(pruned)", group_hash: Railwatch::Record.group_hash("SolidQueue::Pruned"),
      duration: 0, occurred_at: 1.hour.ago)
    Railwatch::Telemetry::Rollup.create!(record_type: "job_attempt", group_hash: pruned.group_hash, name: "(pruned)",
      bucket: Railwatch::Telemetry::Rollup.bucket_for(1.hour.ago), count: 1)

    found = Railwatch::FilterQuery.apply(execution.jobs, resource: :jobs, query: "class:(pruned)", from: 1.day.ago, to: Time.current)
    expect(found).to contain_exactly(pruned)
  end

  it "finds a just-recorded attempt of such a class before its rollup exists" do
    pruned = execution.create!(kind: "job_attempt", name: "(pruned)", group_hash: Railwatch::Record.group_hash("SolidQueue::Pruned"),
      duration: 0, occurred_at: 1.minute.ago)

    found = Railwatch::FilterQuery.apply(execution.jobs, resource: :jobs, query: "class:(pruned)", from: 1.day.ago, to: Time.current)
    expect(found).to contain_exactly(pruned)
  end

  it "walks the window for a class the rollups say is common, where the newest page comes first" do
    busy = run("job_attempt", "BusyJob", at: 1.hour.ago)
    Railwatch::Telemetry::Rollup.create!(record_type: "job_attempt", group_hash: busy.group_hash, name: "BusyJob",
      bucket: Railwatch::Telemetry::Rollup.bucket_for(1.hour.ago), count: Railwatch::Telemetry::Execution::DENSE_MATCHES)

    found = Railwatch::FilterQuery.apply(execution.jobs, resource: :jobs, query: "class:BusyJob", from: 1.day.ago, to: Time.current)
    expect(found).to contain_exactly(busy)
    expect(found.to_sql).not_to include("INDEXED BY")
  end

  it "reads each task's newest schedule, and skips keys that never ran" do
    run("scheduled_task", "cleanup", task_key: "cleanup", at: 2.hours.ago, schedule: "every hour")
    run("scheduled_task", "cleanup", task_key: "cleanup", at: 1.hour.ago, schedule: "every 5 minutes")
    run("scheduled_task", "digest", task_key: "digest", at: 1.hour.ago, schedule: "every monday at 8am")

    expect(execution.latest_schedules(%w[cleanup digest never_ran]))
      .to eq("cleanup" => "every 5 minutes", "digest" => "every monday at 8am")
    expect(execution.latest_schedules([])).to eq({})
  end
end
