# frozen_string_literal: true

require "spec_helper"
require "puma/plugin"
require "puma/plugin/railwatch"

# How the Puma plugin stops the writer. Real forked children, not doubles:
# this is a signal/wait interaction, and a stub of Process.wait would pass
# whether or not the wait was bounded.
RSpec.describe "the Railwatch Puma plugin stopping its writer" do
  let(:log) { [] }
  around do |example|
    was = Railwatch.config.shutdown_timeout
    example.run
  ensure
    Railwatch.config.shutdown_timeout = was
  end
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
    # The real budget, not a stub of it: the bound is shutdown_timeout and
    # the example must fail if that stops being where the number comes from.
    Railwatch.config.shutdown_timeout = 0.3

    elapsed = stop_with_writer(pid)

    expect(elapsed).to be_between(0.3, 1.5)
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

  it "budgets the stop at shutdown_timeout, the same allowance the process gives its own reporter" do
    Railwatch.config.shutdown_timeout = 2.0

    expect(plugin.send(:stop_timeout)).to eq(2.0)
  end
end

# The supervisor's liveness check. Real forked children through the real
# Writer.fork_writer!, with only what the child runs swapped out: a signal-0
# check passes for a hung child exactly as for a healthy one, so this has
# to be a process that is really alive and really not listening.
RSpec.describe "the Railwatch Puma plugin supervising its writer" do
  let(:log) { [] }
  let(:socket_path) { File.join(Dir.mktmpdir("rw-sup"), "w.sock") }
  let(:plugin) do
    Puma::Plugins.find("railwatch").new.tap do |p|
      p.instance_variable_set(:@log_writer, Class.new { def initialize(lines) = @lines = lines; def log(m) = @lines << m }.new(log))
      p.instance_variable_set(:@puma_pid, Process.pid)
      p.instance_variable_set(:@shutting_down, false)
      p.instance_variable_set(:@booted, true)
    end
  end
  let(:spawned) { [] }

  around do |example|
    was = [ Railwatch.config.transport, Railwatch.config.writer_socket ]
    Railwatch.config.transport = :local
    Railwatch.config.writer_socket = socket_path
    example.run
  ensure
    Railwatch.config.transport, Railwatch.config.writer_socket = was
  end

  before do
    # Scaled down from 2s / 15s so each example runs in about a second; the
    # shape is the production one (the grace is several polls long).
    stub_const("POLL", 0.05)
    stub_const("WRITER_BIND_GRACE", 0.5)
  end

  # In `after`, not the around's ensure: the supervisor has to be stopped
  # while fork_writer! is still stubbed, or its next poll forks a real one.
  after do
    plugin.instance_variable_set(:@shutting_down, true)
    @supervisor&.join(2) || @supervisor&.kill
    spawned.each do |pid|
      Process.kill(:KILL, pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  # What production saw: a child that never reaches the point of binding,
  # blocked on a lock with no owner. It ignores TERM, as a thread parked in
  # a native lock never returns to run a Ruby trap handler.
  def hang
    trap("TERM") { nil }
    IO.pipe.first.read
  end

  # A writer that binds the way the real one does (Writer.bind, which clears
  # the stale socket file a killed predecessor left) and answers connects.
  def serve(path, for_seconds: nil)
    Railwatch::Writer.bind(path)
    server = Railwatch::Writer.instance_variable_get(:@server)
    closer = Thread.new { sleep for_seconds; server.close } if for_seconds
    loop { server.accept.close }
  rescue IOError
    closer&.join
    hang # the listener is gone; the process lingers
  end

  # Each fork runs the next behaviour; the last one repeats.
  def with_writers(*behaviours)
    allow(Railwatch::Writer).to receive(:fork_writer!).and_wrap_original do |original, &_block|
      behaviour = behaviours.length > 1 ? behaviours.shift : behaviours.first
      # exit! either way: a child that raised out of the block would run
      # this process's at_exit handlers, RSpec's included.
      original.call do
        behaviour.call
      rescue Exception # rubocop:disable Lint/RescueException
        exit!(1)
      end.tap { |pid| spawned << pid }
    end
    allow(Railwatch::Writer).to receive(:run!)
    @supervisor = Thread.new { plugin.send(:supervise) }
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_for(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.02 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  it "kills a writer that is alive but never binds its socket, and replaces it within the grace" do
    path = socket_path
    with_writers(-> { hang }, -> { serve(path) })

    expect(wait_for(3) { spawned.length >= 2 && Railwatch::Writer.listening?(path) }).to be(true)
    hung, replacement = spawned
    # Killed with KILL (it ignores TERM) and reaped, not left as a zombie.
    expect(alive?(hung)).to be(false)
    expect(log).to include(a_string_matching(/\ARailwatch writer \(pid #{hung}\) never bound its socket after \d+s \(limit 0.5s\); killing and restarting\z/))
    expect(plugin.writer_pid).to eq(replacement)
    expect(alive?(replacement)).to be(true)
  end

  it "keeps replacing a writer that hangs again, rather than giving up after one attempt" do
    with_writers(-> { hang })

    expect(wait_for(4) { spawned.length >= 3 }).to be(true)
    expect(spawned.first(2).none? { |pid| alive?(pid) }).to be(true)
    expect(log.grep(/never bound its socket/).length).to be >= 2
  end

  it "never touches a healthy writer, however long it runs past the bind grace" do
    path = socket_path
    with_writers(-> { serve(path) })

    sleep 1.5 # three bind graces, thirty polls
    expect(spawned.length).to eq(1)
    expect(alive?(spawned.first)).to be(true)
    expect(Railwatch::Writer.listening?(path)).to be(true)
    expect(log).to eq([ "Railwatch writer started (pid #{spawned.first})" ])
  end

  it "replaces a writer that bound and then stopped answering while its process lingered" do
    path = socket_path
    with_writers(-> { serve(path, for_seconds: 0.3) }, -> { serve(path) })

    expect(wait_for(3) { spawned.length >= 2 && Railwatch::Writer.listening?(path) }).to be(true)
    expect(alive?(spawned.first)).to be(false)
    expect(log).to include(a_string_matching(/\(pid #{spawned.first}\) stopped answering on its socket \(3 consecutive checks\); killing and restarting/))
    expect(log.grep(/never bound/)).to be_empty
  end

  it "still restarts a writer that died, without calling it hung" do
    path = socket_path
    with_writers(-> { exit!(1) }, -> { serve(path) })

    expect(wait_for(3) { spawned.length >= 2 && Railwatch::Writer.listening?(path) }).to be(true)
    expect(log).to include("Railwatch writer (pid #{spawned.first}) is gone; starting")
    expect(log.grep(/killing and restarting/)).to be_empty
  end
end
