# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::Execution do
  def new_execution(**opts)
    described_class.new(source: :request, sampled: true, **opts)
  end

  describe "stage durations" do
    it "sum to within 1ms of the total duration when every microsecond is inside a stage" do
      exe = new_execution
      exe.enter_stage(:routing)
      sleep 0.01
      exe.enter_stage(:action)
      sleep 0.01
      exe.finish_stages
      total = exe.duration

      sum = exe.stage_durations.values.sum
      expect(sum).to be_within(1_000).of(total)
    end

    it "keys stage_durations by stage name with integer microsecond values" do
      exe = new_execution
      exe.enter_stage(:routing)
      sleep 0.005
      exe.enter_stage(:action)
      sleep 0.005
      exe.finish_stages

      expect(exe.stage_durations.keys).to eq(%i[routing action])
      exe.stage_durations.each_value do |micros|
        expect(micros).to be_a(Integer)
        expect(micros).to be >= 5_000
      end
    end
  end

  describe "#buffer" do
    it "drops and counts records once MAX_RECORDS is reached, keeping earlier ones" do
      exe = new_execution
      described_class::MAX_RECORDS.times { |i| exe.buffer(i) }
      exe.buffer(:overflow_1)
      exe.buffer(:overflow_2)

      expect(exe.records.size).to eq(described_class::MAX_RECORDS)
      expect(exe.records.first).to eq(0)
      expect(exe.records.last).to eq(described_class::MAX_RECORDS - 1)
      expect(exe.dropped_records).to eq(2)
    end
  end

  describe "#envelope" do
    it "reflects the current stage as it advances, and starts with a nil stage" do
      exe = new_execution
      expect(exe.envelope[:execution_stage]).to be_nil

      exe.enter_stage(:routing)
      expect(exe.envelope[:execution_stage]).to eq("routing")

      exe.enter_stage(:action)
      expect(exe.envelope[:execution_stage]).to eq("action")

      exe.finish_stages
      expect(exe.envelope[:execution_stage]).to be_nil
    end

    it "flows user_id and tenant into every record built for the execution" do
      exe = new_execution
      exe.user_id = "user-42"
      exe.tenant = "acme"

      record = Lantern::Record.build(:query, exe, sql: "select 1")

      expect(record[:user]).to eq("user-42")
      expect(record[:tenant]).to eq("acme")
    end

    it "carries execution_source, execution_id, and trace_id from the execution" do
      exe = new_execution
      record = Lantern::Record.build(:query, exe, sql: "select 1")

      expect(record[:execution_source]).to eq("request")
      expect(record[:execution_id]).to eq(exe.id)
      expect(record[:trace_id]).to eq(exe.trace_id)
    end
  end

  describe "paused_depth nesting" do
    it "resumes recording only once the outermost Lantern.ignore block returns" do
      exe = new_execution

      Lantern::Current.with(exe) do
        expect(exe.recording?).to be(true)

        Lantern.ignore do
          expect(exe.paused_depth).to eq(1)
          expect(exe.recording?).to be(false)

          Lantern.ignore do
            expect(exe.paused_depth).to eq(2)
            expect(exe.recording?).to be(false)
          end

          expect(exe.paused_depth).to eq(1)
          expect(exe.recording?).to be(false)
        end

        expect(exe.paused_depth).to eq(0)
        expect(exe.recording?).to be(true)
      end
    end
  end

  describe "#capture_memory" do
    it "returns the process RSS in bytes on Linux" do
      exe = new_execution
      exe.capture_memory
      expect(exe.peak_memory).to be_a(Integer)
      expect(exe.peak_memory).to be > 0
    end

    it "keeps the last good sample when /proc/self/statm becomes unreadable" do
      exe = new_execution
      Lantern::Execution.instance_variable_set(:@memory_sampled_at, 0.0)
      Lantern::Execution.instance_variable_set(:@memory_sample, nil)
      allow(File).to receive(:read).with("/proc/self/statm").and_raise(Errno::ENOENT)

      exe.capture_memory
      expect(exe.peak_memory).to be_nil
    end
  end
end
