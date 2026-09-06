# frozen_string_literal: true

require "spec_helper"

RSpec.describe "health record" do
  # Puma and Solid Queue are both real dependencies of this suite, but neither
  # has anything to report here (no Puma::Server is ever booted, and the dummy
  # app has no Solid Queue tables), so both are replaced with the minimum
  # surface Lantern::Health actually reads.
  let(:oldest_ready_at) { Time.utc(2026, 9, 3, 12, 0, 0) }

  # Health only ever calls #count on what `group`/`where` return, the way an
  # Active Record relation behaves.
  let(:relation) { Struct.new(:count) }

  let(:fake_puma_server) do
    Class.new do
      def stats
        { backlog: 3, running: 5, pool_capacity: 0, max_threads: 5, busy_threads: 4, requests_count: 1_234 }
      end
    end
  end

  let(:fake_ready_execution) do
    counted = relation
    oldest = oldest_ready_at
    Class.new do
      define_singleton_method(:count) { 7 }
      define_singleton_method(:minimum) { |_column| oldest }
      define_singleton_method(:group) { |_column| counted.new({ "default" => 5, "urgent" => 2 }) }
    end
  end

  let(:fake_solid_queue_process) do
    counted = relation
    Class.new { define_singleton_method(:where) { |_conditions| counted.new(2) } }
  end

  before do
    # Execution.sampled_memory memoizes process-wide for a second, and
    # execution_spec deliberately leaves a nil sample behind, so force a fresh
    # read the same way that spec does.
    Lantern::Execution.instance_variable_set(:@memory_sampled_at, 0.0)
    # puma_server is memoized for the life of the process, so the lookup has
    # to be re-armed for each example.
    Lantern::Health.remove_instance_variable(:@puma_server) if Lantern::Health.instance_variable_defined?(:@puma_server)
    stub_const("Puma::Server", fake_puma_server)
    stub_const("SolidQueue::ReadyExecution", fake_ready_execution)
    stub_const("SolidQueue::Process", fake_solid_queue_process)
  end

  # Health finds the server through ObjectSpace, so one has to actually exist.
  def boot_puma_server
    @server = Puma::Server.new
  end

  it "captures pid, role, memory, Puma, connection pool, and Solid Queue stats in one record" do
    boot_puma_server

    Lantern::Health.sample

    health = lantern_records(:health).sole
    expect(health[:pid]).to eq(Process.pid)
    expect(health[:role]).to eq("web")
    expect(health[:memory]).to be_a(Integer).and be > 0
    expect(health[:threads_max]).to eq(5)
    expect(health[:threads_busy]).to eq(4)
    expect(health[:backlog]).to eq(3)
    expect(health[:pool_size]).to eq(ActiveRecord::Base.connection_pool.stat[:size])
    expect(health[:pool_busy]).to be_a(Integer)
    expect(health[:pool_waiting]).to eq(0)
    expect(health[:queue_depth]).to eq(7)
  end

  it "reports queue_latency as the age of the oldest ready job, in microseconds" do
    Lantern::Health.sample

    expected = (Lantern::Clock.now - oldest_ready_at.to_f) * 1_000_000
    expect(lantern_records(:health).sole[:queue_latency]).to be_within(60_000_000).of(expected)
  end

  it "packs queues, workers, requests_count, running, and max_threads_reached into detail" do
    boot_puma_server

    Lantern::Health.sample

    detail = JSON.parse(lantern_records(:health).sole[:detail])
    expect(detail["queues"]).to eq("default" => 5, "urgent" => 2)
    expect(detail["workers"]).to eq(2)
    expect(detail["requests_count"]).to eq(1_234)
    expect(detail["running"]).to eq(5)
    expect(detail["max_threads_reached"]).to be(true) # pool_capacity was 0
  end

  it "packs the recurring task schedule into detail, so the platform knows which tasks are still configured" do
    allow(Lantern::Subscribers::Jobs).to receive(:recurring_tasks).and_return(
      keys: %w[nightly_cleanup], classes: %w[CleanupJob], schedules: { "nightly_cleanup" => "0 2 * * *" })

    Lantern::Health.sample

    expect(JSON.parse(lantern_records(:health).sole[:detail])["recurring_tasks"]).to eq("nightly_cleanup" => "0 2 * * *")
  end

  it "leaves recurring_tasks out of detail entirely when none are configured or the table could not be read" do
    allow(Lantern::Subscribers::Jobs).to receive(:recurring_tasks).and_return(keys: [], classes: [], schedules: {})

    Lantern::Health.sample

    expect(JSON.parse(lantern_records(:health).sole[:detail])).not_to have_key("recurring_tasks")
  end

  it "leaves every Puma stat nil when no Puma::Server has been booted" do
    Lantern::Health.sample

    health = lantern_records(:health).sole
    expect(health[:threads_max]).to be_nil
    expect(health[:threads_busy]).to be_nil
    expect(health[:backlog]).to be_nil
    expect(JSON.parse(health[:detail])["running"]).to be_nil
  end

  it "leaves every Solid Queue stat nil when Solid Queue is not loaded" do
    hide_const("SolidQueue")

    Lantern::Health.sample

    health = lantern_records(:health).sole
    expect(health[:queue_depth]).to be_nil
    expect(health[:queue_latency]).to be_nil
    expect(JSON.parse(health[:detail])["workers"]).to be_nil
  end

  it "still ships the rest of the record when a Solid Queue query blows up" do
    allow(SolidQueue::ReadyExecution).to receive(:count).and_raise(ActiveRecord::StatementInvalid, "no such table")

    Lantern::Health.sample

    health = lantern_records(:health).sole
    expect(health[:queue_depth]).to be_nil
    expect(health[:pid]).to eq(Process.pid)
  end

  it "never raises out of a sample, even when writing the record fails" do
    allow(Lantern).to receive(:record).and_raise("boom")

    expect(Lantern::Health.sample).to be_nil
  end
end

RSpec.describe Lantern::Health do
  describe ".start!" do
    it "does not start a thread in the test environment" do
      described_class.start!
      expect(described_class.instance_variable_get(:@thread)).to be_nil
    end

    it "does not start a thread for a console or command process" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(Lantern::Subscribers::ProcessInfo).to receive(:role).and_return("command")

      described_class.start!
      expect(described_class.instance_variable_get(:@thread)).to be_nil
    end

    it "starts exactly one thread for a web process, and stop! shuts it down" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(Lantern::Subscribers::ProcessInfo).to receive(:role).and_return("web")
      # A 30s interval means the thread parks on the ConditionVariable and
      # never actually samples; stop! must still return promptly.
      Lantern.config.health_interval = 30.0

      described_class.start!
      thread = described_class.instance_variable_get(:@thread)
      described_class.start!

      expect(thread).to be_alive
      expect(described_class.instance_variable_get(:@thread)).to equal(thread)

      described_class.stop!
      expect(thread).not_to be_alive
      expect(described_class.instance_variable_get(:@thread)).to be_nil
    ensure
      described_class.stop!
      Lantern.config.health_interval = 15.0
    end
  end
end

RSpec.describe "Lantern::Health fork state" do
  it "replaces synchronization state inherited by the child" do
    old_mutex = Lantern::Health.instance_variable_get(:@mutex)
    old_wakeup = Lantern::Health.instance_variable_get(:@wakeup)

    Lantern::Health.restart_after_fork!

    expect(Lantern::Health.instance_variable_get(:@mutex)).not_to equal(old_mutex)
    expect(Lantern::Health.instance_variable_get(:@wakeup)).not_to equal(old_wakeup)
    expect(Lantern::Health.instance_variable_get(:@pid)).to be_nil
  end
end
