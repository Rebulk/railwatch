# frozen_string_literal: true

require "spec_helper"

RSpec.describe "tail sampling", type: :request do
  before { Widget.create!(name: "w", gadget: Gadget.create!(name: "g")) }
  after { Railwatch.config.tail_sample_slow_ms = nil }

  def finish_command
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                             command: "rake demo", exit_code: 0)
  end

  it "ships the whole tree of a head-sampled-out request that ran at least tail_sample_slow_ms" do
    Railwatch.config.sample[:requests] = 0.0
    Railwatch.config.tail_sample_slow_ms = 0.0 # every request is "slow"
    get "/widgets"

    expect(railwatch_records(:query)).not_to be_empty
    expect(railwatch_records(:log)).not_to be_empty
    expect(railwatch_records(:request).sole[:tail_sampled]).to be(true)
  end

  it "ships nothing for a head-sampled-out request that finished faster than tail_sample_slow_ms" do
    Railwatch.config.sample[:requests] = 0.0
    Railwatch.config.tail_sample_slow_ms = 60_000.0
    get "/widgets"

    expect(railwatch_records).to be_empty
  end

  it "leaves a normally sampled-in request unmarked, since it was never a tail decision" do
    Railwatch.config.tail_sample_slow_ms = 0.0
    get "/widgets"

    expect(railwatch_records(:request).sole).not_to have_key(:tail_sampled)
  end

  it "ships nothing extra when tail sampling is off, exactly as before" do
    Railwatch.config.sample[:requests] = 0.0
    get "/widgets"

    expect(railwatch_records).to be_empty
  end

  it "ships the children of a sampled-out execution that raised, once tail sampling is on" do
    require "rake"
    Rake::Task.define_task(:railwatch_tail_boom) do
      Widget.count
      raise ArgumentError, "kaboom"
    end
    Railwatch.config.sample[:commands] = 0.0
    Railwatch.config.tail_sample_slow_ms = 60_000.0 # not slow enough to qualify on duration

    expect { Rake::Task[:railwatch_tail_boom].execute }.to raise_error(ArgumentError)

    expect(railwatch_records(:query)).not_to be_empty
    expect(railwatch_records(:exception).sole[:handled]).to be(false)
    expect(railwatch_records(:command).sole[:tail_sampled]).to be(true)
  end

  it "still ships only the parent for a sampled-out execution that raised when tail sampling is off" do
    require "rake"
    Rake::Task.define_task(:railwatch_no_tail_boom) do
      Widget.count
      raise ArgumentError, "kaboom"
    end
    Railwatch.config.sample[:commands] = 0.0

    expect { Rake::Task[:railwatch_no_tail_boom].execute }.to raise_error(ArgumentError)

    expect(railwatch_records(:query)).to be_empty
    expect(railwatch_records(:command).sole).not_to have_key(:tail_sampled)
  end

  describe "Railwatch.keep!" do
    it "ships the whole tree of a sampled-out execution even with tail sampling off" do
      Railwatch.config.sample[:commands] = 0.0
      Railwatch.start_execution(source: :command, sample_kind: :commands)
      Railwatch.keep!
      Railwatch.record(:log, level: "info", message: "kept", tags: [], context: "{}")
      finish_command

      expect(railwatch_records(:log).sole[:message]).to eq("kept")
      expect(railwatch_records(:command).sole[:tail_sampled]).to be(true)
    end

    it "cannot resurrect records made before it, which were never buffered" do
      Railwatch.config.sample[:commands] = 0.0
      Railwatch.start_execution(source: :command, sample_kind: :commands)
      Railwatch.record(:log, level: "info", message: "before", tags: [], context: "{}")
      Railwatch.keep!
      Railwatch.record(:log, level: "info", message: "after", tags: [], context: "{}")
      finish_command

      expect(railwatch_records(:log).map { |l| l[:message] }).to eq([ "after" ])
    end

    it "does nothing outside an execution" do
      expect { Railwatch.keep! }.not_to raise_error
    end
  end

  # profile_slow_ms rides on tail sampling: a slow execution has to be
  # profiled from its first line, long before anyone knows it is slow.
  describe "profile_slow_ms" do
    before do
      # The head profile_sample roll must never fire here, so profile_slow_ms
      # is the only thing that can pick an execution. A non-zero rate is
      # still needed: the test env profiles only when one is set.
      allow(Random).to receive(:rand).and_return(0.99)
      Railwatch.config.profile_sample = 0.5
      Railwatch.config.profile_interval_us = 500
    end

    after do
      Railwatch.config.profile_sample = 0.0
      Railwatch.config.profile_slow_ms = nil
      Railwatch.config.profile_interval_us = 1_000
      Railwatch::Profiler.reset!
    end

    it "ships the profile of a tail-buffering request that ran at least profile_slow_ms" do
      Railwatch.config.tail_sample_slow_ms = 500.0
      Railwatch.config.profile_slow_ms = 0.0 # every request is "slow"
      get "/widgets"

      expect(railwatch_records(:profile).sole[:profiler]).to eq("vernier")
      expect(railwatch_records(:request).sole[:profiled]).to be(true)
    end

    it "throws the profile away when the request finished faster than profile_slow_ms" do
      Railwatch.config.tail_sample_slow_ms = 500.0
      Railwatch.config.profile_slow_ms = 60_000.0
      get "/widgets"

      expect(railwatch_records(:profile)).to be_empty
      expect(railwatch_records(:request).sole).not_to have_key(:profiled)
    end

    it "never starts a profile when tail sampling is off" do
      Railwatch.config.profile_slow_ms = 0.0
      exe = Railwatch.start_execution(source: :command, sample_kind: :commands)

      expect(exe.tail_buffering?).to be(false)
      expect(exe.profiler_handle).to be_nil

      finish_command
      expect(railwatch_records(:profile)).to be_empty
    end
  end

  describe "Execution#recording?" do
    it "is unchanged for a sampled-out execution when tail sampling is off" do
      exe = Railwatch::Execution.new(source: :request, sampled: false)

      expect(exe.recording?).to be(false)
      expect(exe.tail_buffering?).to be(false)
    end

    it "buffers a sampled-out execution's children once tail_sample_slow_ms is set" do
      Railwatch.config.tail_sample_slow_ms = 500.0
      exe = Railwatch::Execution.new(source: :request, sampled: false)

      expect(exe.recording?).to be(true)
      expect(exe.keep).to be(false)
    end

    it "starts buffering from the moment keep! is called" do
      exe = Railwatch::Execution.new(source: :request, sampled: false)
      expect(exe.recording?).to be(false)

      exe.keep!
      expect(exe.recording?).to be(true)
      expect(exe.keep).to be(true)
    end

    it "stays paused inside Railwatch.ignore even when buffering for the tail" do
      Railwatch.config.tail_sample_slow_ms = 500.0
      exe = Railwatch::Execution.new(source: :request, sampled: false)
      exe.paused_depth += 1

      expect(exe.recording?).to be(false)
    end
  end
end
