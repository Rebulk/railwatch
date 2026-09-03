# frozen_string_literal: true

require "spec_helper"

RSpec.describe "process record" do
  it "captures pid, role, ruby/rails/lantern versions, adapters, cache store, and boot_seconds" do
    Lantern::Subscribers::ProcessInfo.install!(Rails.application)

    proc_rec = lantern_records(:process).sole
    expect(proc_rec[:pid]).to eq(Process.pid)
    expect(proc_rec[:role]).to eq("web") # Puma is loaded as a test dependency, so it wins role detection
    expect(proc_rec[:ruby_version]).to eq(RUBY_VERSION)
    expect(proc_rec[:rails_version]).to eq(Rails.version)
    expect(proc_rec[:lantern_version]).to eq(Lantern::VERSION)
    expect(proc_rec[:app]).to eq("Dummy")
    expect(proc_rec[:environment]).to eq("test")
    expect(proc_rec[:boot_seconds]).to be_a(Float).and be >= 0
    expect(proc_rec[:database_adapter]).to eq("sqlite3")
    expect(proc_rec[:queue_adapter]).to eq("test")
    expect(proc_rec[:cache_store]).to eq("ActiveSupport::Cache::MemoryStore")
  end

  describe ".role" do
    # Puma is a real dependency of this test suite (pulled in by rspec-rails/
    # capybara), so ::Puma is already defined and would win every branch below
    # unless hidden first.
    before { hide_const("Puma") if defined?(::Puma) }

    it "is web when Puma is defined" do
      stub_const("Puma", Module.new)
      expect(Lantern::Subscribers::ProcessInfo.role).to eq("web")
    end

    it "is worker when SolidQueue is defined and $PROGRAM_NAME includes jobs" do
      stub_const("SolidQueue", Module.new)
      with_program_name("bin/jobs") { expect(Lantern::Subscribers::ProcessInfo.role).to eq("worker") }
    end

    it "is worker for `rails solid_queue:start` even though Puma is loaded" do
      stub_const("Puma", Module.new)
      stub_const("SolidQueue", Module.new)
      stub_const("ARGV", [ "solid_queue:start" ])
      with_program_name("bin/rails") { expect(Lantern::Subscribers::ProcessInfo.role).to eq("worker") }
    end

    it "is console when Rails::Console is defined" do
      stub_const("Rails::Console", Class.new)
      expect(Lantern::Subscribers::ProcessInfo.role).to eq("console")
    end

    it "is command when $PROGRAM_NAME ends with rake" do
      with_program_name("/usr/bin/rake") { expect(Lantern::Subscribers::ProcessInfo.role).to eq("command") }
    end

    it "falls back to process when nothing else matches" do
      with_program_name("irb") { expect(Lantern::Subscribers::ProcessInfo.role).to eq("process") }
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
