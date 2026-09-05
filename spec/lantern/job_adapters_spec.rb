# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::JobAdapters do
  it "records a scheduler-independent manual check-in and returns the block value" do
    run_at = Time.at(Lantern::Clock.now - 3).utc

    result = Lantern.scheduled_task("billing.nightly", schedule: "0 2 * * *", run_at: run_at, adapter: "cron") do
      Lantern.span("billing.rollup") { :rolled_up }
    end

    expect(result).to eq(:rolled_up)
    task = lantern_records(:scheduled_task).sole
    expect(task).to include(
      task_key: "billing.nightly", name: "billing.nightly",
      schedule: "0 2 * * *", adapter: "cron", status: "processed")
    expect(task[:drift]).to be_within(1_000_000).of(3_000_000)
    expect(lantern_records(:span).sole[:execution_id]).to eq(task[:execution_id])
  end

  it "captures a failed manual check-in and re-raises the same exception" do
    error = RuntimeError.new("rollup failed")

    expect do
      Lantern.scheduled_task("billing.nightly") { raise error }
    end.to raise_error { |raised| expect(raised).to equal(error) }

    expect(lantern_records(:scheduled_task).sole).to include(
      task_key: "billing.nightly", status: "failed",
      exception_preview: "RuntimeError: rollup failed")
  end

  it "lets another adapter supply schedule metadata through the public SPI" do
    adapter = Module.new do
      module_function

      def available? = true
      def schedule_metadata(payload) = payload[:schedule]
    end
    old_adapters = described_class.adapters
    described_class.register(:test_scheduler, adapter)
    payload = { schedule: { task_key: "custom", schedule: "every hour", run_at: Lantern::Clock.now } }
    metadata = {
      adapter: "Custom", job_id: "one", provider_job_id: "one", name: "Worker",
      queue: "custom", attempt: 1, enqueued_at: nil, will_retry: false, arguments_preview: []
    }

    described_class.instrument_perform(adapter: :test_scheduler, payload: payload, metadata: metadata) { :done }

    expect(lantern_records(:scheduled_task).sole).to include(task_key: "custom", schedule: "every hour")
  ensure
    described_class.instance_variable_set(:@adapters, old_adapters)
  end

  it "executes exactly once without creating state when Lantern is disabled" do
    allow(Lantern).to receive(:enabled?).and_return(false)
    calls = 0

    result = Lantern.scheduled_task("disabled") { calls += 1; :done }

    expect(result).to eq(:done)
    expect(calls).to eq(1)
    expect(Lantern.execution).to be_nil
  end
end
