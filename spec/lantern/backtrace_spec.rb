# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::Backtrace do
  let(:app_file) { "#{described_class.app_root}app/models/widget.rb" }

  def wrapper_with_string_backtrace(lines)
    error = RuntimeError.new("wrapped")
    error.set_backtrace(lines)
    error
  end

  describe ".frames" do
    it "reads frames from backtrace_locations when the exception was raised" do
      error = begin
        raise ArgumentError, "raised"
      rescue ArgumentError => e
        e
      end

      frames = described_class.frames(error, with_source: false)
      expect(frames.first).to include(file: a_string_ending_with("backtrace_spec.rb"), line: a_kind_of(Integer))
    end

    # ActiveRecord::StatementInvalid gets its backtrace via set_backtrace from
    # the driver error, and Faraday::Error delegates #backtrace to the wrapped
    # exception; both leave backtrace_locations nil.
    it "falls back to parsing the String backtrace when backtrace_locations is nil" do
      error = wrapper_with_string_backtrace([
        "#{app_file}:12:in 'Widget#save'",
        "/gems/activerecord/lib/active_record/base.rb:40:in `block in run'",
        "/gems/faraday/lib/faraday/adapter.rb:7"
      ])
      expect(error.backtrace_locations).to be_nil

      frames = described_class.frames(error, with_source: false)
      expect(frames).to eq([
        { file: "app/models/widget.rb", line: 12, function: "Widget#save", in_app: true },
        { file: "/gems/activerecord/lib/active_record/base.rb", line: 40, function: "block in run", in_app: false },
        { file: "/gems/faraday/lib/faraday/adapter.rb", line: 7, function: nil, in_app: false }
      ])
    end

    it "drops backtrace lines it cannot parse rather than raising" do
      error = wrapper_with_string_backtrace([ "not a frame", "#{app_file}:3:in 'x'" ])
      expect(described_class.frames(error, with_source: false).map { |f| f[:line] }).to eq([ 3 ])
    end

    it "returns no frames for an exception that was never raised and has no backtrace" do
      expect(described_class.frames(RuntimeError.new("fresh"), with_source: false)).to eq([])
    end
  end
end
