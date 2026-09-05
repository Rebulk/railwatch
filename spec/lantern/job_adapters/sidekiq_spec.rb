# frozen_string_literal: true

require "spec_helper"
require "net/http"

RSpec.describe Lantern::JobAdapters::Sidekiq do
  subject(:server) { described_class::ServerMiddleware.new }

  around do |example|
    old_used = described_class.instance_variable_get(:@used)
    example.run
  ensure
    described_class.instance_variable_set(:@used, old_used)
  end

  let(:direct_payload) do
    {
      "class" => "Invoices::ChargeJob",
      "jid" => "sidekiq-jid",
      "queue" => "critical",
      "args" => [ 42, { "force" => true } ],
      "created_at" => Lantern::Clock.now - 2,
      "enqueued_at" => Lantern::Clock.now - 1
    }
  end

  def finish_command
    Lantern.finish_execution(:command, group: "sidekiq-client", class: "Rake::Task",
      name: "demo", command: "rake demo", exit_code: 0)
  end

  def sidekiq_timestamp(seconds, major:)
    major >= 8 ? (seconds * 1_000).to_i : seconds.to_f
  end

  it "propagates trace and identity and records direct client pushes" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern.execution.user_id = "account-1:user-7"
    Lantern.execution.tenant = "account-1"
    trace_id = Lantern.execution.trace_id
    parent_id = Lantern.execution.id
    payload = direct_payload.dup

    result = described_class::ClientMiddleware.new.call("Invoices::ChargeJob", payload, "critical") { :pushed }
    finish_command

    expect(result).to eq(:pushed)
    expect(payload["_lantern"]).to include(
      "trace_id" => trace_id, "parent_id" => parent_id,
      "user" => "account-1:user-7", "tenant" => "account-1",
      "sampled" => true)
    expect(lantern_records(:enqueued_job).sole).to include(
      job_id: "sidekiq-jid", name: "Invoices::ChargeJob",
      queue: "critical", adapter: "Sidekiq", failed: false)
  end

  it "propagates the effective sampled decision after keep! promotes a trace" do
    Lantern.config.sample[:commands] = 0.0
    Lantern.start_execution(source: :command, sample_kind: :commands)
    expect(Lantern.execution).not_to be_sampled
    Lantern.keep!
    payload = direct_payload.dup

    described_class::ClientMiddleware.new.call("Invoices::ChargeJob", payload, "critical") { :pushed }
    finish_command

    expect(payload.dig("_lantern", "sampled")).to be(true)
    expect(lantern_records(:command)).to contain_exactly(include(trace_id: payload.dig("_lantern", "trace_id")))
    expect(lantern_records(:enqueued_job)).to contain_exactly(include(job_id: "sidekiq-jid"))
  end

  it "passes enqueue failures through unchanged and records one failed push" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    calls = 0
    payload = direct_payload.dup

    expect do
      described_class::ClientMiddleware.new.call("Invoices::ChargeJob", payload, "critical") do
        calls += 1
        raise NoMemoryError, "queue unavailable"
      end
    end.to raise_error(NoMemoryError, "queue unavailable")
    finish_command

    expect(calls).to eq(1)
    expect(lantern_records(:enqueued_job).sole[:failed]).to be(true)
  end

  it "never executes a successful push twice when recording raises" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    allow(Lantern).to receive(:record).and_raise("telemetry broke")
    calls = 0

    result = described_class::ClientMiddleware.new.call("Invoices::ChargeJob", direct_payload.dup, "critical") do
      calls += 1
      :pushed
    end

    expect(result).to eq(:pushed)
    expect(calls).to eq(1)
  ensure
    Lantern.finish_execution if Lantern.execution
  end

  it "opens a linked job execution around a direct worker and captures nested work" do
    parent_trace = SecureRandom.uuid
    parent_id = SecureRandom.uuid
    payload = direct_payload.merge(
      "_lantern" => {
        "trace_id" => parent_trace, "parent_id" => parent_id,
        "user" => "account-1:user-7", "tenant" => "account-1", "sampled" => true
      })

    result = server.call(Object.new, payload, "critical") do
      Lantern.span("invoice.charge") { Net::HTTP.get(URI("http://example.test/sidekiq")); :charged }
    end

    expect(result).to eq(:charged)
    attempt = lantern_records(:job_attempt).sole
    expect(attempt).to include(
      trace_id: parent_trace, parent_id: parent_id,
      user: "account-1:user-7", tenant: "account-1",
      job_id: "sidekiq-jid", provider_job_id: "sidekiq-jid",
      name: "Invoices::ChargeJob", queue: "critical", adapter: "Sidekiq",
      attempt: 1, status: "processed")
    expect(attempt[:queue_latency]).to be_a(Integer).and be >= 0
    expect(lantern_records(:span).sole).to include(trace_id: parent_trace, execution_id: attempt[:execution_id])
    expect(lantern_records(:outgoing_request).sole).to include(trace_id: parent_trace, execution_id: attempt[:execution_id])
    expect(Lantern.execution).to be_nil
  end

  it "normalizes real Sidekiq 7 second and Sidekiq 8 millisecond timestamps" do
    now = Lantern::Clock.now

    [ 7, 8 ].each do |major|
      payload = direct_payload.merge(
        "jid" => "sidekiq-#{major}",
        "enqueued_at" => sidekiq_timestamp(now - 1, major: major))
      server.call(Object.new, payload, "critical") { :done }
    end

    latencies = lantern_records(:job_attempt).to_h { |attempt| [ attempt[:job_id], attempt[:queue_latency] ] }
    expect(latencies.keys).to contain_exactly("sidekiq-7", "sidekiq-8")
    expect(latencies.values).to all(be_between(500_000, 2_500_000))
  end

  it "accepts the timestamp shape generated by the installed Sidekiq API" do
    normalized = Object.new.extend(::Sidekiq::JobUtil).normalize_item(
      "class" => "Invoices::ChargeJob", "queue" => "critical", "args" => [])
    payload = direct_payload.merge("enqueued_at" => normalized.fetch("created_at"))

    server.call(Object.new, payload, "critical") { :done }

    expect(lantern_records(:job_attempt).sole[:queue_latency]).to be_between(0, 2_500_000)
  end

  it "keeps Sidekiq 8 timestamp units when malformed optional metadata uses the fallback" do
    payload = direct_payload.merge(
      "retry_count" => "not-an-integer",
      "enqueued_at" => sidekiq_timestamp(Lantern::Clock.now - 1, major: 8))

    server.call(Object.new, payload, "critical") { :done }

    expect(lantern_records(:job_attempt).sole).to include(attempt: nil)
      .and include(queue_latency: be_between(500_000, 2_500_000))
  end

  it "honours an enqueuing trace's sampled decision when the local job rate is zero" do
    Lantern.config.sample[:jobs] = 0.0
    payload = direct_payload.merge("_lantern" => { "trace_id" => SecureRandom.uuid, "sampled" => true })

    server.call(Object.new, payload, "critical") { Lantern.span("kept.downstream") { :done } }

    expect(lantern_records(:job_attempt).sole[:trace_id]).to eq(payload.dig("_lantern", "trace_id"))
    expect(lantern_records(:span).sole[:name]).to eq("kept.downstream")
  end

  it "propagates a direct worker execution into direct jobs it enqueues" do
    child = direct_payload.merge("jid" => "child-jid")
    parent_execution_id = nil
    parent_trace_id = nil

    server.call(Object.new, direct_payload, "critical") do
      parent_execution_id = Lantern.execution.id
      parent_trace_id = Lantern.execution.trace_id
      described_class::ClientMiddleware.new.call("Invoices::ChargeJob", child, "critical") { :pushed }
    end

    expect(child["_lantern"]).to include("parent_id" => parent_execution_id, "trace_id" => parent_trace_id)
    expect(lantern_records(:enqueued_job).sole).to include(execution_id: parent_execution_id, trace_id: parent_trace_id)
  end

  it "marks retryable failures released and re-raises the same exception" do
    error = ArgumentError.new("declined")

    expect { server.call(Object.new, direct_payload, "critical") { raise error } }.to raise_error { |raised| expect(raised).to equal(error) }

    attempt = lantern_records(:job_attempt).sole
    expect(attempt).to include(status: "released", attempt: 1)
    expect(attempt[:exception_preview]).to eq("ArgumentError: declined")
    expect(lantern_records(:exception).sole[:class]).to eq("ArgumentError")
  end

  it "marks retry-disabled and exhausted attempts failed" do
    no_retry = direct_payload.merge("jid" => "discarded", "retry" => false)
    exhausted = direct_payload.merge("jid" => "dead", "retry" => 2, "retry_count" => 1)
    expired_v7 = direct_payload.merge(
      "jid" => "expired-v7", "retry_for" => 60,
      "failed_at" => sidekiq_timestamp(Lantern::Clock.now - 61, major: 7), "retry_count" => 0)
    expired_v8 = direct_payload.merge(
      "jid" => "expired-v8", "retry_for" => 60,
      "failed_at" => sidekiq_timestamp(Lantern::Clock.now - 61, major: 8), "retry_count" => 0)

    expect { server.call(Object.new, no_retry, "critical") { raise "discard" } }.to raise_error("discard")
    expect { server.call(Object.new, exhausted, "critical") { raise "dead" } }.to raise_error("dead")
    expect { server.call(Object.new, expired_v7, "critical") { raise "expired-v7" } }.to raise_error("expired-v7")
    expect { server.call(Object.new, expired_v8, "critical") { raise "expired-v8" } }.to raise_error("expired-v8")

    expect(lantern_records(:job_attempt).map { |attempt| [ attempt[:job_id], attempt[:status], attempt[:attempt] ] })
      .to contain_exactly(
        [ "discarded", "failed", 1 ], [ "dead", "failed", 3 ],
        [ "expired-v7", "failed", 2 ], [ "expired-v8", "failed", 2 ])
  end

  it "lets retry_for continue past the ordinary attempt ceiling in Sidekiq 8" do
    stub_const("Sidekiq::MAJOR", 8)
    now = Lantern::Clock.now
    payload = direct_payload.merge(
      "jid" => "duration-sidekiq-8",
      "retry_for" => 86_400,
      "failed_at" => sidekiq_timestamp(now, major: 8),
      "retry_count" => described_class::DEFAULT_RETRIES - 1)

    expect { server.call(Object.new, payload, "critical") { raise "retry-for-8" } }
      .to raise_error("retry-for-8")

    expect(lantern_records(:job_attempt).map { |attempt| [ attempt[:job_id], attempt[:status] ] })
      .to contain_exactly([ "duration-sidekiq-8", "released" ])
  end

  it "still enforces the ordinary attempt ceiling with retry_for in Sidekiq 7" do
    stub_const("Sidekiq::MAJOR", 7)
    payload = direct_payload.merge(
      "jid" => "duration-sidekiq-7",
      "retry_for" => 86_400,
      "failed_at" => sidekiq_timestamp(Lantern::Clock.now, major: 7),
      "retry_count" => described_class::DEFAULT_RETRIES - 1)

    expect { server.call(Object.new, payload, "critical") { raise "retry-for-7" } }
      .to raise_error("retry-for-7")

    expect(lantern_records(:job_attempt).sole).to include(
      job_id: "duration-sidekiq-7", status: "failed")
  end

  it "reports a hard shutdown as requeued without creating an application exception" do
    payload = direct_payload.merge("retry" => false)

    expect { server.call(Object.new, payload, "critical") { raise Sidekiq::Shutdown } }
      .to raise_error(Sidekiq::Shutdown)

    expect(lantern_records(:job_attempt).sole).to include(
      job_id: "sidekiq-jid", status: "released", exception_preview: nil)
    expect(lantern_records(:exception)).to be_empty
  end

  it "recognizes a hard shutdown wrapped as another exception cause" do
    payload = direct_payload.merge("retry" => false)

    expect do
      server.call(Object.new, payload, "critical") do
        raise Sidekiq::Shutdown
      rescue Sidekiq::Shutdown
        raise "cleanup failed"
      end
    end.to raise_error("cleanup failed")

    expect(lantern_records(:job_attempt).sole).to include(
      job_id: "sidekiq-jid", status: "released", exception_preview: nil)
    expect(lantern_records(:exception)).to be_empty
  end

  it "turns sidekiq-cron payloads into scheduled task executions with drift" do
    payload = direct_payload.merge(
      "cron_job_id" => "nightly-invoices",
      "_lantern" => {
        "task_key" => "nightly-invoices", "schedule" => "0 2 * * *",
        "run_at" => Lantern::Clock.now - 5
      })

    server.call(Object.new, payload, "critical") { :done }

    task = lantern_records(:scheduled_task).sole
    expect(task).to include(task_key: "nightly-invoices", schedule: "0 2 * * *", status: "processed")
    expect(task[:drift]).to be_within(1_000_000).of(5_000_000)
    expect(lantern_records(:job_attempt)).to be_empty
  end

  it "carries a non-Solid scheduler marker through Active Job serialization" do
    serialized = Lantern::JobAdapters.with_schedule(
      task_key: "billing:nightly", schedule: "0 2 * * *", run_at: Time.utc(2026, 9, 5, 2)) do
      WidgetJob.new("bob").serialize
    end
    job = WidgetJob.new
    job.deserialize(serialized)

    expect(job).to have_attributes(
      lantern_task_key: "billing:nightly",
      lantern_schedule: "0 2 * * *",
      lantern_scheduled_at: Time.utc(2026, 9, 5, 2).to_f)

    job.perform_now
    expect(lantern_records(:scheduled_task).sole).to include(
      task_key: "billing:nightly", schedule: "0 2 * * *", name: "WidgetJob")
  end

  def cron_job_class(enqueue_method)
    cron_class = Class.new do
      attr_reader :name, :namespace, :cron, :observed
      def initialize
        @name = "nightly"
        @namespace = "billing"
        @cron = "0 2 * * *"
      end
      define_method(enqueue_method) do |time = Time.now.utc|
        @observed = Lantern::JobAdapters.current_schedule
        "jid"
      end
    end
    cron_class
  end

  def expect_cron_enqueue_metadata(enqueue_method)
    stub_const("Sidekiq::Cron::Job", cron_job_class(enqueue_method))
    described_class.install_cron_hook!
    run_at = Time.utc(2026, 9, 5, 2)
    cron = Sidekiq::Cron::Job.new

    expect(cron.public_send(enqueue_method, run_at)).to eq("jid")
    expect(cron.observed).to eq(task_key: "billing:nightly", schedule: "0 2 * * *", run_at: run_at)
    expect(Lantern::JobAdapters.current_schedule).to be_nil
  end

  it "wraps sidekiq-cron 2.x enqueue! with isolated scheduler metadata" do
    expect_cron_enqueue_metadata(:enqueue!)
  end

  it "wraps sidekiq-cron 1.x enque! with isolated scheduler metadata" do
    expect_cron_enqueue_metadata(:enque!)
  end

  it "captures and redacts direct arguments only when explicitly enabled" do
    Lantern.config.capture_job_arguments = true
    payload = direct_payload.merge("args" => [ { "email" => "a@example.test", "password" => "secret" } ])

    server.call(Object.new, payload, "critical") { :done }

    expect(lantern_records(:job_attempt).sole[:arguments].sole)
      .to eq("email" => "a@example.test", "password" => "[FILTERED]")
  ensure
    Lantern.config.capture_job_arguments = false
  end

  it "does not duplicate Active Job's Sidekiq wrapper" do
    payload = direct_payload.merge(
      "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
      "wrapped" => "WidgetJob")
    calls = 0

    expect(server.call(Object.new, payload, "default") { calls += 1; :done }).to eq(:done)

    expect(calls).to eq(1)
    expect(lantern_records(:job_attempt)).to be_empty
  end

  it "isolates simultaneous worker executions and restores each thread" do
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        payload = direct_payload.merge("jid" => "jid-#{index}")
        server.call(Object.new, payload, "critical") do
          ready << [ index, Lantern.execution.id ]
          release.pop
          Lantern.span("worker.#{index}") { :done }
        end
        raise "execution leaked" if Lantern.execution
      end
    end
    executions = 2.times.map { ready.pop }.to_h
    2.times { release << true }
    threads.each(&:value)

    attempts = lantern_records(:job_attempt).to_h { |attempt| [ attempt[:job_id], attempt ] }
    expect(attempts.keys).to contain_exactly("jid-0", "jid-1")
    expect(attempts.values.map { |attempt| attempt[:execution_id] }).to contain_exactly(*executions.values)
    expect(lantern_records(:span).map { |span| span[:execution_id] }).to contain_exactly(*executions.values)
  end

  it "reports direct Sidekiq queue depth, latency, per-queue counts, and workers" do
    queue_class = Class.new do
      attr_reader :name, :size, :latency
      def initialize(name, size, latency) = (@name, @size, @latency = name, size, latency)
      define_singleton_method(:all) { [ new("default", 3, 1.5), new("critical", 2, 0.25) ] }
    end
    process_set = Class.new { def size = 4 }
    sidekiq = Module.new do
      define_singleton_method(:configure_client) { |_block = nil, &block| }
      define_singleton_method(:server?) { true }
    end
    sidekiq.const_set(:Queue, queue_class)
    sidekiq.const_set(:ProcessSet, process_set)
    stub_const("Sidekiq", sidekiq)
    hide_const("SolidQueue")

    expect(Lantern::JobAdapters.queue_health).to eq(
      queue_depth: 5, queue_latency: 1_500_000,
      queues: { "default" => 3, "critical" => 2 }, workers: 4,
      adapters: { "sidekiq" => true })
  end


  it "can inspect registered adapters in a fork even when registration was locked at fork time" do
    skip "fork unavailable" unless Process.respond_to?(:fork)

    mutex = Lantern::JobAdapters.instance_variable_get(:@mutex)
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      mutex.synchronize do
        locked << true
        release.pop
      end
    end
    locked.pop
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(Lantern::JobAdapters.adapters.keys.join(","))
      writer.close
      exit! 0
    end
    writer.close
    expect(reader.read).to include("sidekiq")
    Process.wait(pid)
    expect($CHILD_STATUS&.success? || $?.success?).to be(true)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    release << true if release
    holder&.join
  end
end
