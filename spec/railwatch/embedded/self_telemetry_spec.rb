# frozen_string_literal: true

require "spec_helper"

# Railwatch must never record telemetry about its own work.
#
# The incident this pins: an embedded install whose writer hung at boot, so
# every app process fell back to Transport::Local. Each batch it wrote ended
# in Ingest::Batch#broadcast_live, and the host's cable adapter was Solid
# Cable with autotrim on, whose #broadcast runs SolidCable::TrimJob.perform_now
# inline. Railwatch instrumented that TrimJob as a job attempt; the attempt
# was the next batch; writing it broadcast again. Batches, broadcasts and
# TrimJob executions each rose roughly 3-5x and the export queue behind them
# fell an hour behind.
#
# Railwatch.ignore could not have stopped it: it pauses the current
# execution's children, the reporter thread has no current execution, and
# a job performed inline opens an execution of its own regardless.
RSpec.describe "Railwatch's own work" do
  around do |example|
    Railwatch.config.transport = :local
    Railwatch::Ingest::Batch::LAST_BROADCAST_AT.clear
    example.run
  ensure
    Railwatch.config.transport = :http
    Railwatch::Ingest::Batch::LAST_BROADCAST_AT.clear
  end

  # Stands in for SolidCable::TrimJob: a job an adapter performs inline,
  # inside ActionCable.server.broadcast.
  let(:trim_job) do
    stub_const("InlineTrimJob", Class.new(ActiveJob::Base) do
      def perform = Railwatch::Environment.current.with_telemetry { Railwatch::Telemetry::IngestBatch.count }
    end)
  end

  # The shape of ActionCable::SubscriptionAdapter::SolidCable#broadcast.
  let(:inline_job_adapter) do
    job = trim_job
    Class.new(ActionCable::SubscriptionAdapter::Base) do
      define_method(:broadcast) { |_channel, _payload| job.perform_now }
      def subscribe(*) = nil
      def unsubscribe(*) = nil
    end
  end

  let(:environment) { Railwatch::Environment.current }

  def telemetry(&) = environment.with_telemetry(&)

  # The telemetry database is not rolled back between examples, so these
  # count what an example added rather than what the table holds.
  def batches = telemetry { Railwatch::Telemetry::IngestBatch.count }

  def request_record
    { "v" => 1, "t" => "request", "timestamp" => Time.now.to_f, "method" => "GET", "route" => "/widgets",
      "controller" => "widgets", "action" => "index", "status_code" => 200, "duration" => 12_000,
      "stages" => { "action" => 10_000 }, "counters" => { "queries" => 1 },
      "execution_id" => SecureRandom.uuid, "_group" => Digest::MD5.hexdigest("req") }
  end

  def with_cable_adapter(adapter)
    server = ActionCable.server
    previous = server.instance_variable_get(:@pubsub)
    server.instance_variable_set(:@pubsub, adapter.new(server))
    yield
  ensure
    server.instance_variable_set(:@pubsub, previous)
  end

  def local_reporter
    Railwatch::Reporter.new(Railwatch.config, transport: Railwatch::Transport::Local.new(Railwatch.config))
      .tap { |reporter| Railwatch.instance_variable_set(:@reporter, reporter) }
  end

  it "does not record the job a cable adapter performs inline while a delivered batch broadcasts" do
    reporter = local_reporter
    performed = 0
    before = batches
    allow(trim_job).to receive(:perform_now).and_wrap_original { |m, *a| performed += 1; m.call(*a) }

    with_cable_adapter(inline_job_adapter) do
      reporter.write(Railwatch::Record.build(:health, nil, pid: Process.pid, role: "web", memory: 1))
      reporter.flush
      # Anything the first delivery produced is buffered now; a second flush
      # is what would carry it, and what would broadcast again.
      Railwatch::Ingest::Batch::LAST_BROADCAST_AT.clear
      reporter.flush
    end

    expect(performed).to eq(1)
    expect(batches - before).to eq(1)
    expect(telemetry { Railwatch::Telemetry::Execution.where(name: "InlineTrimJob").count }).to eq(0)
    expect(reporter.buffer.stats.first).to eq(0)
  ensure
    reporter&.shutdown
  end

  it "does not record it when the writer process serves the batch either" do
    with_cable_adapter(inline_job_adapter) do
      result = Railwatch::Writer.write_batch("records" => [ request_record ], "batch_id" => SecureRandom.uuid)
      expect(result.ok).to be(true)
    end

    expect(railwatch_records).to be_empty
  end

  it "does not attribute a batch written by an in-request flush to that request" do
    reporter = local_reporter
    before = batches
    Railwatch.start_execution(source: :request).sampled = true
    Railwatch.record(:log, level: "info", message: "before", tags: [], context: "{}")
    buffered_before = Railwatch.execution.records.size

    reporter.write(Railwatch::Record.build(:health, nil, pid: Process.pid, role: "web", memory: 1))
    Railwatch.flush
    buffered_after = Railwatch.execution.records.size
    Railwatch.finish_execution

    expect(buffered_after).to eq(buffered_before)
    expect(batches - before).to eq(1)
  ensure
    Railwatch.finish_execution if Railwatch.execution
    reporter&.shutdown
  end

  describe "Railwatch.internal" do
    it "ships nothing for a job performed inside it, and restores the caller's execution" do
      outer = Railwatch.start_execution(source: :request)
      outer.sampled = true

      Railwatch.internal do
        expect(Railwatch.execution).to be_nil
        WidgetJob.perform_now("gear")
        Railwatch.record(:health, pid: 1, role: "web", memory: 1)
      end

      expect(Railwatch.execution).to be(outer)
      Railwatch.finish_execution(:request, method: "GET", route: "/", status_code: 200)
      expect(railwatch_records.map { |r| r[:t] }).to eq([ "request" ])
      expect(railwatch_records.sole[:execution_id]).to eq(outer.id)
    end

    it "drops an exception reported from inside it rather than opening an issue about Railwatch" do
      Railwatch.internal { Rails.error.report(RuntimeError.new("broadcast failed"), handled: true) }

      expect(railwatch_records(:exception)).to be_empty
    end

    it "nests, and leaves the thread recording again once the outermost block ends" do
      Railwatch.internal { Railwatch.internal { nil } }
      expect(Railwatch::Current.internal?).to be(false)

      WidgetJob.perform_now("gear")
      expect(railwatch_records(:job_attempt).map { |r| r[:name] }).to eq([ "WidgetJob" ])
    end

    it "is not Railwatch.ignore: application work inside ignore still opens its own execution" do
      Railwatch.ignore { WidgetJob.perform_now("gear") }

      expect(railwatch_records(:job_attempt).map { |r| r[:name] }).to eq([ "WidgetJob" ])
    end
  end
end
