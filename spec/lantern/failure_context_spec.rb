# frozen_string_literal: true

require "spec_helper"
require "rake"

RSpec.describe "failure context", type: :request do
  before { Widget.create!(name: "w", gadget: Gadget.create!(name: "g")) }

  after do
    Lantern.config.failure_context = 0
    Lantern.config.tail_sample_slow_ms = nil
  end

  def start_command
    Lantern.config.sample[:commands] = 0.0
    Lantern.start_execution(source: :command, sample_kind: :commands)
  end

  def finish_command
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                             command: "rake demo", exit_code: 0)
  end

  def log(message)
    Lantern.record(:log, level: "info", message: message, tags: [], context: "{}")
  end

  describe "a head-sampled-out request" do
    before do
      Lantern.config.sample[:requests] = 0.0
      Lantern.config.failure_context = 200
    end

    it "ships the child records that led up to an unhandled exception, with the exception and the parent" do
      get "/boom"

      expect(lantern_records(:exception).sole).to include(class: "ArgumentError", handled: false)
      expect(lantern_records(:query)).not_to be_empty
      expect(lantern_records(:request).sole).to include(status_code: 500, tail_sampled: true)
    end

    it "ships nothing at all when it completes normally" do
      get "/widgets"

      expect(lantern_records).to be_empty
    end

    it "ships nothing when the exceptions rate is 0, exactly as with the ring off" do
      Lantern.config.sample[:exceptions] = 0.0
      get "/boom"

      expect(lantern_records).to be_empty
    end

    it "never promotes the ring for a handled exception" do
      get "/handled"

      expect(lantern_records).to be_empty
    end

    it "still lets a late Lantern.sample(1.0) ship the whole execution" do
      get "/override_sample", params: { mode: "on" }

      expect(lantern_records(:request).sole[:status_code]).to eq(200)
      expect(lantern_records(:query)).not_to be_empty
    end

    it "keeps shipping only the lone parent once failure_context is back off" do
      Lantern.config.failure_context = 0
      get "/boom"

      expect(lantern_records(:query)).to be_empty
      expect(lantern_records(:request).sole).not_to have_key(:tail_sampled)
    end
  end

  describe "a head-sampled-out Active Job attempt" do
    before do
      Lantern.config.sample[:jobs] = 0.0
      Lantern.config.failure_context = 200
    end

    it "ships its queries and logs when the job raises" do
      expect { WidgetJob.perform_now("bob", fail: true) }.to raise_error(RuntimeError)

      expect(lantern_records(:query)).not_to be_empty
      expect(lantern_records(:exception).sole[:handled]).to be(false)
      expect(lantern_records(:job_attempt).sole).to include(status: "failed", tail_sampled: true)
    end

    it "ships nothing when the job succeeds" do
      WidgetJob.perform_now("bob")

      expect(lantern_records).to be_empty
    end
  end

  describe "a head-sampled-out scheduled task" do
    # Same Solid Queue fixture the scheduled_task record spec uses: a
    # RecurringTask plus a RecurringExecution pointed at this job_id is what
    # makes Subscribers::Jobs open a :scheduled_task execution.
    before(:context) do
      schema_path = Gem.find_files("generators/solid_queue/install/templates/db/queue_schema.rb").first
      body = File.readlines(schema_path)[1..-2].join
      SolidQueue::Record.connection.instance_eval(body)
    end

    before do
      Lantern.config.sample[:scheduled_tasks] = 0.0
      Lantern.config.failure_context = 200
    end

    def register_recurring(key, job)
      SolidQueue::RecurringTask.create!(key: key, class_name: job.class.name, schedule: "*/5 * * * *", static: true)
      sq_job = SolidQueue::Job.create!(queue_name: job.queue_name, class_name: job.class.name,
                                       active_job_id: job.job_id, priority: 0)
      SolidQueue::RecurringExecution.create!(task_key: key, run_at: Time.current, job_id: sq_job.id)
      Lantern::Subscribers::Jobs.refresh_recurring_tasks!
    end

    it "ships its child records when the task raises" do
      job = WidgetJob.new("bob", fail: true)
      register_recurring("widget_failure_context", job)

      expect { job.perform_now }.to raise_error(RuntimeError)

      expect(lantern_records(:query)).not_to be_empty
      expect(lantern_records(:scheduled_task).sole).to include(task_key: "widget_failure_context", tail_sampled: true)
    end

    it "ships nothing when the task succeeds" do
      job = WidgetJob.new("bob")
      register_recurring("widget_failure_context_ok", job)

      job.perform_now

      expect(lantern_records).to be_empty
    end
  end

  describe "a head-sampled-out command" do
    before { Lantern.config.failure_context = 200 }

    it "ships the queries a failing rake task ran before it raised" do
      Rake::Task.define_task(:lantern_failure_context_boom) do
        Widget.count
        raise ArgumentError, "kaboom"
      end
      Lantern.config.sample[:commands] = 0.0

      expect { Rake::Task[:lantern_failure_context_boom].execute }.to raise_error(ArgumentError)

      expect(lantern_records(:query)).not_to be_empty
      expect(lantern_records(:exception).sole[:handled]).to be(false)
      expect(lantern_records(:command).sole[:tail_sampled]).to be(true)
    end

    it "ships nothing for a rake task that completes" do
      Rake::Task.define_task(:lantern_failure_context_ok) { Widget.count }
      Lantern.config.sample[:commands] = 0.0

      Rake::Task[:lantern_failure_context_ok].execute

      expect(lantern_records).to be_empty
    end

    it "never promotes the ring for an ignored exception class" do
      start_command
      log("before")
      Lantern.report(ActiveRecord::RecordNotFound.new("Couldn't find Widget"), handled: false)
      finish_command

      expect(lantern_records).to be_empty
    end

    it "never promotes the ring for an exception reported inside Lantern.ignore, shipping only the parent" do
      start_command
      log("before")
      Lantern.ignore { Lantern.report(RuntimeError.new("paused"), handled: false) }
      finish_command

      expect(lantern_records(:log)).to be_empty
      expect(lantern_records(:exception)).to be_empty
      expect(lantern_records(:command).sole).not_to have_key(:tail_sampled)
    end

    it "never promotes the ring for an interactive `rails runner`, whose exceptions are the operator's" do
      exe = start_command
      exe.interactive = true
      log("before")
      Lantern.report(RuntimeError.new("typo"), handled: false)
      finish_command

      expect(lantern_records(:log)).to be_empty
      expect(lantern_records(:exception)).to be_empty
    end
  end

  describe "bounded memory" do
    it "keeps only the last failure_context records of a long-running sampled-out execution, counting the rest as dropped" do
      Lantern.config.failure_context = 200
      exe = start_command
      10_000.times { |i| log("line #{i}") }

      expect(exe.records.size).to eq(200)
      expect(exe.records.first[:message]).to eq("line 9800")
      expect(exe.records.last[:message]).to eq("line 9999")
      expect(exe.dropped_records).to eq(9_800)

      finish_command
      expect(lantern_records).to be_empty
    end

    it "accounts the overflow onto the batch's dropped count when the ring is promoted" do
      Lantern.config.failure_context = 10
      start_command
      25.times { |i| log("line #{i}") }
      Lantern.report(RuntimeError.new("boom"), handled: false)
      finish_command

      expect(Lantern.reporter.buffer.dropped).to eq(15)
      expect(lantern_records(:log).map { |r| r[:message] }).to eq((15..24).map { |i| "line #{i}" })
    end

    it "keeps every concurrent execution's ring bounded and separate" do
      Lantern.config.failure_context = 50
      Lantern.config.sample[:jobs] = 0.0

      executions = 4.times.map do |t|
        Thread.new do
          exe = Lantern.start_execution(source: :job, sample_kind: :jobs)
          2_000.times { |i| log("t#{t}-#{i}") }
          Lantern.finish_execution
          exe
        end
      end.map(&:value)

      expect(executions.map { |e| e.records.size }).to all(eq(50))
      expect(executions.map(&:dropped_records)).to all(eq(1_950))
      executions.each_with_index do |exe, t|
        expect(exe.records.map { |r| r[:message] }).to all(start_with("t#{t}-"))
        expect(exe.records.last[:message]).to eq("t#{t}-1999")
      end
      expect(lantern_records).to be_empty
    end
  end

  describe "Execution" do
    def sampled_out_execution
      Lantern::Execution.new(source: :request, sampled: false)
    end

    it "records nothing for a sampled-out execution while failure_context is 0, which is the default" do
      exe = sampled_out_execution

      expect(Lantern.config.failure_context).to eq(0)
      expect(exe.recording?).to be(false)
      expect(exe.failure_context?).to be(false)
    end

    it "never rings a head-sampled-in execution" do
      Lantern.config.failure_context = 200
      exe = Lantern::Execution.new(source: :request, sampled: true)

      expect(exe.failure_context?).to be(false)
      expect(exe.tail_buffering?).to be(false)
    end

    it "leaves tail sampling's larger buffer in charge when both are configured" do
      Lantern.config.failure_context = 2
      Lantern.config.tail_sample_slow_ms = 500.0
      exe = sampled_out_execution
      5.times { |i| exe.buffer(i) }

      expect(exe.failure_context?).to be(false)
      expect(exe.records.size).to eq(5)
      expect(exe.dropped_records).to eq(0)
    end

    it "stops ringing once Lantern.keep! takes over the execution" do
      Lantern.config.failure_context = 2
      exe = sampled_out_execution
      3.times { |i| exe.buffer(i) }
      exe.keep!
      3.times { |i| exe.buffer(i + 10) }

      expect(exe.failure_context?).to be(false)
      expect(exe.records).to eq([ 1, 2, 10, 11, 12 ])
      expect(exe.dropped_records).to eq(1)
    end

    it "stays paused inside Lantern.ignore even while ringing" do
      Lantern.config.failure_context = 200
      exe = sampled_out_execution
      exe.paused_depth += 1

      expect(exe.recording?).to be(false)
    end
  end
end
