# frozen_string_literal: true

require "spec_helper"
require "puma/plugin"
require "puma/plugin/railwatch"

# How the Puma plugin stops the writer. Real forked children, not doubles:
# this is a signal/wait interaction, and a stub of Process.wait would pass
# whether or not the wait was bounded.
RSpec.describe "the Railwatch Puma plugin stopping its writer" do
  let(:log) { [] }
  let(:plugin) do
    Puma::Plugins.find("railwatch").new.tap do |p|
      p.instance_variable_set(:@log_writer, Class.new { def initialize(lines) = @lines = lines; def log(m) = @lines << m }.new(log))
    end
  end

  def stop_with_writer(pid)
    plugin.instance_variable_set(:@writer_pid, pid)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    plugin.send(:stop_writer)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  it "kills a writer that does not leave on TERM, inside its budget, and reaps it" do
    # What a writer stuck in a SQLite write or on a full disk looks like from
    # outside: TERM lands and nothing happens.
    pid = fork do
      trap("TERM") { nil }
      loop { sleep }
    end
    sleep 0.1
    allow(plugin).to receive(:stop_timeout).and_return(0.3)

    elapsed = stop_with_writer(pid)

    expect(elapsed).to be_between(0.3, 2.0)
    expect(alive?(pid)).to be(false)
    expect(plugin.writer_pid).to be_nil
    expect(log).to include(a_string_matching(/did not exit within 0.3s of TERM; killing it/))
  ensure
    Process.kill(:KILL, pid) rescue nil
    Process.wait(pid) rescue nil
  end

  it "lets a writer that exits on TERM go as soon as it does, not at the end of the budget" do
    pid = fork do
      trap("TERM") { exit!(0) }
      loop { sleep }
    end
    sleep 0.1

    elapsed = stop_with_writer(pid)

    expect(elapsed).to be < 1.0
    expect(alive?(pid)).to be(false)
    expect(plugin.writer_pid).to be_nil
    expect(log).to be_empty
  end

  it "treats a writer the cluster already reaped as gone" do
    pid = fork { exit!(0) }
    Process.wait(pid)

    expect { stop_with_writer(pid) }.not_to raise_error
    expect(plugin.writer_pid).to be_nil
  end

  it "gives a healthy writer its whole drain and reporter shutdown before killing it" do
    Railwatch.config.shutdown_timeout = 2.0

    expect(plugin.send(:stop_timeout)).to eq(Railwatch::Writer::SHUTDOWN_DRAIN + 1 + 2.0)
  end
end
