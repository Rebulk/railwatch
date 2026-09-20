# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Backtrace do
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

  describe ".source_snippet" do
    around do |example|
      Dir.mktmpdir("railwatch-source") do |directory|
        @root = File.join(directory, "app")
        FileUtils.mkdir_p(@root)
        @secret = File.join(directory, "private.key")
        File.write(@secret, "private-secret")
        example.run
      end
    end

    before { allow(described_class).to receive(:app_root).and_return(@root + "/") }

    it "reads regular application source with line numbers" do
      file = File.join(@root, "example.rb")
      File.write(file, "first\nsecond\nthird\n")
      expect(described_class.source_snippet(file, 2, context: 1)).to eq(1 => "first", 2 => "second", 3 => "third")
    end

    it "does not disclose a file reached through a traversal in a string backtrace" do
      error = wrapper_with_string_backtrace([ "#{@root}/../private.key:1" ])
      expect(described_class.frames(error).first[:code]).to be_nil
    end

    it "does not follow an application symlink outside the application" do
      link = File.join(@root, "linked.rb")
      File.symlink(@secret, link)
      expect(described_class.source_snippet(link, 1)).to be_nil
    end

    it "does not load unbounded source files" do
      file = File.join(@root, "large.rb")
      File.write(file, "x" * (described_class::MAX_SOURCE_BYTES + 1))
      expect(described_class.source_snippet(file, 1)).to be_nil
    end
  end
end
