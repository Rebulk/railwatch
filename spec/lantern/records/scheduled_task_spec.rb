# frozen_string_literal: true

require "spec_helper"

RSpec.describe "scheduled_task record" do
  # Solid Queue's schema lives on a separate "queue" database
  # (config.solid_queue.connects_to in spec/dummy/config/application.rb) that
  # nothing else in this dummy app has populated yet. Load the gem's own
  # install-generator schema onto that connection once, self-contained to
  # this file, rather than touching the shared spec_helper/database setup.
  before(:context) do
    schema_path = Gem.find_files("generators/solid_queue/install/templates/db/queue_schema.rb").first
    body = File.readlines(schema_path)[1..-2].join
    SolidQueue::Record.connection.instance_eval(body)
  end

  # A SolidQueue::RecurringTask + a SolidQueue::Job/RecurringExecution pair
  # wired to job.job_id is exactly what Jobs.recurring_task_key looks up --
  # it doesn't require an actual Solid Queue worker to have run anything.
  def register_recurring(key, job, schedule: "*/5 * * * *")
    task = SolidQueue::RecurringTask.create!(key: key, class_name: job.class.name, schedule: schedule, static: true)
    sq_job = SolidQueue::Job.create!(queue_name: job.queue_name, class_name: job.class.name, active_job_id: job.job_id, priority: 0)
    SolidQueue::RecurringExecution.create!(task_key: task.key, run_at: Time.current, job_id: sq_job.id)
    # The gem caches the recurring task table for a minute (it is static
    # config in production); a task registered mid-test needs a refresh.
    Lantern::Subscribers::Jobs.refresh_recurring_tasks!
    task
  end

  it "ships a scheduled_task record (not a job_attempt) with the task_key and schedule, for a job Solid Queue recorded a RecurringExecution for" do
    job = WidgetJob.new("bob")
    register_recurring("widget_recurring", job, schedule: "*/5 * * * *")

    job.perform_now

    expect(lantern_records(:job_attempt)).to be_empty
    task = lantern_records(:scheduled_task).sole
    expect(task[:task_key]).to eq("widget_recurring")
    expect(task[:schedule]).to eq("*/5 * * * *")
    expect(task[:name]).to eq("WidgetJob")
    expect(task[:status]).to eq("processed")
  end

  it "ships an ordinary job_attempt, not a scheduled_task, for a job with no matching RecurringExecution" do
    WidgetJob.new("plain").perform_now

    expect(lantern_records(:scheduled_task)).to be_empty
    expect(lantern_records(:job_attempt).sole[:name]).to eq("WidgetJob")
  end

  it "distinguishes two recurring tasks pointed at the same job class by their task_key" do
    job_a = WidgetJob.new("a")
    job_b = WidgetJob.new("b")
    register_recurring("widget_every_5m", job_a, schedule: "*/5 * * * *")
    register_recurring("widget_every_hour", job_b, schedule: "0 * * * *")

    job_a.perform_now
    job_b.perform_now

    keys = lantern_records(:scheduled_task).map { |t| t[:task_key] }
    expect(keys.sort).to eq(%w[widget_every_5m widget_every_hour])
  end

  it "computes drift between the scheduled run and the actual perform" do
    pending "bug: the spec-plan requires a scheduled_task :drift field (difference between the " \
            "recurring task's scheduled run_at and when it actually started performing), but " \
            "Lantern::Subscribers::Jobs never computes or ships one -- grep for \"drift\" across " \
            "lib/ and app/ turns up nothing. SolidQueue::RecurringExecution#run_at is available at " \
            "perform time (the same join recurring_task_key already performs), so drift could be " \
            "computed as queue_latency is, in the perform_start.active_job subscriber."
    job = WidgetJob.new("bob")
    register_recurring("widget_recurring", job)

    job.perform_now

    expect(lantern_records(:scheduled_task).sole[:drift]).to be_a(Integer)
  end
end
