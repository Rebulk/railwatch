# frozen_string_literal: true

require "spec_helper"

RSpec.describe "process record" do
  it "captures pid, role, ruby/rails/railwatch versions, adapters, cache store, and boot_seconds" do
    Railwatch::Subscribers::ProcessInfo.install!(Rails.application)
    Railwatch::Subscribers::ProcessInfo.record!

    proc_rec = railwatch_records(:process).sole
    expect(proc_rec[:pid]).to eq(Process.pid)
    expect(proc_rec[:role]).to eq("web") # Puma is loaded as a test dependency, so it wins role detection
    expect(proc_rec[:ruby_version]).to eq(RUBY_VERSION)
    expect(proc_rec[:rails_version]).to eq(Rails.version)
    expect(proc_rec[:railwatch_version]).to eq(Railwatch::VERSION)
    expect(proc_rec[:app]).to eq("Dummy")
    expect(proc_rec[:environment]).to eq("test")
    expect(proc_rec[:boot_seconds]).to be_a(Float).and be >= 0
    expect(proc_rec[:database_adapter]).to eq("sqlite3")
    expect(proc_rec[:queue_adapter]).to eq("test")
    expect(proc_rec[:cache_store]).to eq("ActiveSupport::Cache::MemoryStore")
  end

  it "boots a lazy-loading process without loading Active Record, Active Job, or Rake, and writes one process record after initialize" do
    # The invariants behind the boot-cost claim, checked in a fresh process
    # because this suite has long since loaded all three. The record used to
    # reach ActiveRecord::Base and ActiveJob::Base for two strings, and the
    # patches used to require rake and railties' runner command, in every
    # boot: some 300 ms nothing else asked for.
    script = <<~RUBY
      ENV["RAILS_ENV"] = "test"
      ENV["RAILWATCH_TOKEN"] = "boot"
      ENV["RAILWATCH_INGEST_URL"] = "http://127.0.0.1:9"
      require #{File.expand_path("../../dummy/config/environment", __dir__).inspect}
      records, = Railwatch.reporter.buffer.drain
      puts JSON.generate(
        active_record_loaded: ActiveRecord.autoload?(:Base).nil?,
        active_job_loaded: ActiveJob.autoload?(:Base).nil?,
        rake_loaded: defined?(::Rake) ? true : false,
        process_records: records.count { |r| r[:t] == "process" },
        boot_seconds: records.find { |r| r[:t] == "process" }&.dig(:boot_seconds))
    RUBY
    out = IO.popen([ RbConfig.ruby, "-e", script ], err: File::NULL, &:read)
    state = JSON.parse(out.lines.last)

    expect(state).to include("active_record_loaded" => false, "active_job_loaded" => false, "rake_loaded" => false, "process_records" => 1)
    expect(state["boot_seconds"]).to be > 0
  end

  it "names the adapters from the app's configuration" do
    Railwatch::Subscribers::ProcessInfo.install!(Rails.application)

    expect(Railwatch::Subscribers::ProcessInfo.database_adapter).to eq("sqlite3")
    expect(Railwatch::Subscribers::ProcessInfo.configured_queue_adapter).to eq("test")
  end

  it "resolves a url-only database.yml, a DATABASE_URL-only app, and a self-named queue adapter" do
    app = Struct.new(:config).new(Struct.new(:database_configuration, :active_job).new(
      { "test" => { "url" => "postgres://u:p@db.example/app" } }, Struct.new(:queue_adapter).new(nil)))
    Railwatch::Subscribers::ProcessInfo.install!(app)
    expect(Railwatch::Subscribers::ProcessInfo.database_adapter).to eq("postgresql")

    url_only = Struct.new(:config).new(Struct.new(:database_configuration, :active_job).new({}, Struct.new(:queue_adapter).new(nil)))
    Railwatch::Subscribers::ProcessInfo.install!(url_only)
    previous_url = ENV["DATABASE_URL"]
    ENV["DATABASE_URL"] = "mysql2://u@h/d"
    begin
      expect(Railwatch::Subscribers::ProcessInfo.database_adapter).to eq("mysql2")
    ensure
      previous_url ? ENV["DATABASE_URL"] = previous_url : ENV.delete("DATABASE_URL")
    end

    named = Class.new { def queue_adapter_name = "acme_queue" }.new
    with_adapter = Struct.new(:config).new(Struct.new(:database_configuration, :active_job).new({}, Struct.new(:queue_adapter).new(named)))
    Railwatch::Subscribers::ProcessInfo.install!(with_adapter)
    expect(Railwatch::Subscribers::ProcessInfo.configured_queue_adapter).to eq("acme_queue")
  ensure
    Railwatch::Subscribers::ProcessInfo.install!(Rails.application)
  end

  it "reports the effective queue adapter once Active Job is loaded, even when it was set on ActiveJob::Base directly" do
    # config.active_job.queue_adapter is the railtie's input, not the
    # result; an app that assigns ActiveJob::Base.queue_adapter in an
    # initializer would otherwise be reported under the config default.
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    Railwatch::Subscribers::ProcessInfo.install!(Rails.application)

    expect(Railwatch::Subscribers::ProcessInfo.queue_adapter).to eq("inline")
    expect(Railwatch::Subscribers::ProcessInfo.configured_queue_adapter).to eq("test")
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  describe ".role" do
    # Puma is a real dependency of this test suite (pulled in by rspec-rails/
    # capybara), so ::Puma is already defined and would win every branch below
    # unless hidden first.
    before { hide_const("Puma") if defined?(::Puma) }

    it "is web when Puma is defined" do
      stub_const("Puma", Module.new)
      expect(Railwatch::Subscribers::ProcessInfo.role).to eq("web")
    end

    it "is worker when SolidQueue is defined and $PROGRAM_NAME includes jobs" do
      stub_const("SolidQueue", Module.new)
      with_program_name("bin/jobs") { expect(Railwatch::Subscribers::ProcessInfo.role).to eq("worker") }
    end

    it "is worker for `rails solid_queue:start` even though Puma is loaded" do
      stub_const("Puma", Module.new)
      stub_const("SolidQueue", Module.new)
      stub_const("ARGV", [ "solid_queue:start" ])
      with_program_name("bin/rails") { expect(Railwatch::Subscribers::ProcessInfo.role).to eq("worker") }
    end

    it "is worker for a process Solid Queue has renamed through its procline" do
      stub_const("Puma", Module.new)
      stub_const("SolidQueue", Module.new)
      with_program_name("solid-queue-dispatcher(1.7.0): dispatching every 1 seconds") do
        expect(Railwatch::Subscribers::ProcessInfo.role).to eq("worker")
      end
    end

    it "is console when Rails::Console is defined" do
      stub_const("Rails::Console", Class.new)
      expect(Railwatch::Subscribers::ProcessInfo.role).to eq("console")
    end

    it "is command when $PROGRAM_NAME ends with rake" do
      with_program_name("/usr/bin/rake") { expect(Railwatch::Subscribers::ProcessInfo.role).to eq("command") }
    end

    it "falls back to process when nothing else matches" do
      with_program_name("irb") { expect(Railwatch::Subscribers::ProcessInfo.role).to eq("process") }
    end

    def with_program_name(name)
      old = $PROGRAM_NAME
      $PROGRAM_NAME = name
      yield
    ensure
      $PROGRAM_NAME = old
    end
  end
end
