# frozen_string_literal: true

require "spec_helper"

RSpec.describe "tail sampling", type: :request do
  before { Widget.create!(name: "w", gadget: Gadget.create!(name: "g")) }
  after { Lantern.config.tail_sample_slow_ms = nil }

  def finish_command
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                             command: "rake demo", exit_code: 0)
  end

  it "ships the whole tree of a head-sampled-out request that ran at least tail_sample_slow_ms" do
    Lantern.config.sample[:requests] = 0.0
    Lantern.config.tail_sample_slow_ms = 0.0 # every request is "slow"
    get "/widgets"

    expect(lantern_records(:query)).not_to be_empty
    expect(lantern_records(:log)).not_to be_empty
    expect(lantern_records(:request).sole[:tail_sampled]).to be(true)
  end

  it "ships nothing for a head-sampled-out request that finished faster than tail_sample_slow_ms" do
    Lantern.config.sample[:requests] = 0.0
    Lantern.config.tail_sample_slow_ms = 60_000.0
    get "/widgets"

    expect(lantern_records).to be_empty
  end

  it "leaves a normally sampled-in request unmarked, since it was never a tail decision" do
    Lantern.config.tail_sample_slow_ms = 0.0
    get "/widgets"

    expect(lantern_records(:request).sole).not_to have_key(:tail_sampled)
  end

  it "ships nothing extra when tail sampling is off, exactly as before" do
    Lantern.config.sample[:requests] = 0.0
    get "/widgets"

    expect(lantern_records).to be_empty
  end

  it "ships the children of a sampled-out execution that raised, once tail sampling is on" do
    require "rake"
    Rake::Task.define_task(:lantern_tail_boom) do
      Widget.count
      raise ArgumentError, "kaboom"
    end
    Lantern.config.sample[:commands] = 0.0
    Lantern.config.tail_sample_slow_ms = 60_000.0 # not slow enough to qualify on duration

    expect { Rake::Task[:lantern_tail_boom].execute }.to raise_error(ArgumentError)

    expect(lantern_records(:query)).not_to be_empty
    expect(lantern_records(:exception).sole[:handled]).to be(false)
    expect(lantern_records(:command).sole[:tail_sampled]).to be(true)
  end

  it "still ships only the parent for a sampled-out execution that raised when tail sampling is off" do
    require "rake"
    Rake::Task.define_task(:lantern_no_tail_boom) do
      Widget.count
      raise ArgumentError, "kaboom"
    end
    Lantern.config.sample[:commands] = 0.0

    expect { Rake::Task[:lantern_no_tail_boom].execute }.to raise_error(ArgumentError)

    expect(lantern_records(:query)).to be_empty
    expect(lantern_records(:command).sole).not_to have_key(:tail_sampled)
  end

  describe "Lantern.keep!" do
    it "ships the whole tree of a sampled-out execution even with tail sampling off" do
      Lantern.config.sample[:commands] = 0.0
      Lantern.start_execution(source: :command, sample_kind: :commands)
      Lantern.keep!
      Lantern.record(:log, level: "info", message: "kept", tags: [], context: "{}")
      finish_command

      expect(lantern_records(:log).sole[:message]).to eq("kept")
      expect(lantern_records(:command).sole[:tail_sampled]).to be(true)
    end

    it "cannot resurrect records made before it, which were never buffered" do
      Lantern.config.sample[:commands] = 0.0
      Lantern.start_execution(source: :command, sample_kind: :commands)
      Lantern.record(:log, level: "info", message: "before", tags: [], context: "{}")
      Lantern.keep!
      Lantern.record(:log, level: "info", message: "after", tags: [], context: "{}")
      finish_command

      expect(lantern_records(:log).map { |l| l[:message] }).to eq([ "after" ])
    end

    it "does nothing outside an execution" do
      expect { Lantern.keep! }.not_to raise_error
    end
  end

  describe "Execution#recording?" do
    it "is unchanged for a sampled-out execution when tail sampling is off" do
      exe = Lantern::Execution.new(source: :request, sampled: false)

      expect(exe.recording?).to be(false)
      expect(exe.tail_buffering?).to be(false)
    end

    it "buffers a sampled-out execution's children once tail_sample_slow_ms is set" do
      Lantern.config.tail_sample_slow_ms = 500.0
      exe = Lantern::Execution.new(source: :request, sampled: false)

      expect(exe.recording?).to be(true)
      expect(exe.keep).to be(false)
    end

    it "starts buffering from the moment keep! is called" do
      exe = Lantern::Execution.new(source: :request, sampled: false)
      expect(exe.recording?).to be(false)

      exe.keep!
      expect(exe.recording?).to be(true)
      expect(exe.keep).to be(true)
    end

    it "stays paused inside Lantern.ignore even when buffering for the tail" do
      Lantern.config.tail_sample_slow_ms = 500.0
      exe = Lantern::Execution.new(source: :request, sampled: false)
      exe.paused_depth += 1

      expect(exe.recording?).to be(false)
    end
  end
end
