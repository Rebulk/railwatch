# frozen_string_literal: true

require "puma/plugin"

# `plugin :railwatch` in config/puma.rb. In embedded mode, forks one
# Railwatch::Writer from the Puma process once it has booted, restarts it if
# it dies, and stops it with Puma. Same shape as Solid Queue's
# `solid_queue_mode :fork`, in both cluster and single mode: a default Rails
# 8 app runs Puma in single mode (no WEB_CONCURRENCY), and that app's
# batches belong off its request threads just as much. The fork happens
# from the plugin's background thread with the app loaded and Rails'
# ForkTracker resetting every Railwatch thread in the child, exactly as it
# does for a Puma cluster worker. A no-op when Railwatch is off or the
# transport is not :local, so it is safe to leave in place.
Puma::Plugin.create do
  attr_reader :log_writer, :writer_pid

  POLL = 2

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$
    @launcher = launcher
    @shutting_down = false
    @booted = false

    return unless active?

    # Cluster workers fork from this process after start and inherit this
    # flag; in single mode this is the serving process itself. Either way the
    # reporter retains batches while the writer is starting rather than
    # writing them in-process (Transport::Socket).
    ::Railwatch::Writer.expected!

    # in_background blocks are collected at plugin start and started by the
    # cluster once, so this has to be registered here, not from after_booted
    # (by then the cluster has already fired them and a late block never
    # runs). It waits for boot itself.
    in_background { supervise }

    launcher.events.after_booted { @booted = true }
    # A phased restart fires before_restart and then, once the new workers
    # are up, after_booted again. The writer is stopped for the restart and
    # the supervisor, which is still running, respawns it when @booted flips
    # back. Only a real stop latches shutdown.
    launcher.events.before_restart { restart_writer }
    launcher.events.after_stopped { shutdown_writer }
  end

  private

  # Puma evaluates config/puma.rb, and so this plugin's start, before the
  # app is loaded. `defined?(Railwatch)` is true as soon as the gem's
  # entrypoint has been required (Bundler.require), which is the normal
  # `rails server` path; a bare `puma` on an app that has not required it yet
  # sees the constant but not the API and must not raise out of Puma's boot.
  def active?
    return false unless defined?(::Railwatch) && ::Railwatch.respond_to?(:enabled?)
    return false unless ::Railwatch.enabled? && ::Railwatch.config.local?

    path = ::Railwatch.config.writer_socket_path
    return false if path.nil?
    return true if ::Railwatch::Writer.usable_path?(path)

    log "Railwatch writer not started: socket path #{path} is #{path.bytesize} bytes, over the " \
        "#{::Railwatch::Writer::MAX_SOCKET_PATH}-byte limit; set RAILWATCH_WRITER_SOCKET to a shorter path. " \
        "Batches are written in-process meanwhile."
    false
  end

  def spawn_writer
    @writer_pid = ::Railwatch::Writer.fork_writer! do
      ::Railwatch::Writer.run!(parent: @puma_pid)
    end
    log "Railwatch writer started (pid #{@writer_pid})"
  rescue SystemCallError => e
    @writer_pid = nil
    log "Railwatch writer could not be forked (#{e.class}: #{e.message}); retrying"
  end

  # Puma's cluster reaps every child with wait2(-1), the writer included, so
  # waitpid on the writer's pid raises ECHILD after it has died. Liveness is
  # asked with signal 0 instead, which works whoever reaped it.
  def supervise
    loop do
      sleep POLL
      break if @shutting_down
      next unless @booted
      next if writer_alive?

      log "Railwatch writer (pid #{@writer_pid}) is gone; starting" if @writer_pid
      spawn_writer
    end
  end

  def writer_alive?
    return false unless @writer_pid

    Process.kill(0, @writer_pid)
    # A zombie the cluster has not reaped yet still answers signal 0.
    !Process.waitpid(@writer_pid, Process::WNOHANG)
  rescue Errno::ESRCH
    false
  rescue Errno::ECHILD
    # Already reaped by the cluster: alive iff it still exists for kill 0.
    begin
      Process.kill(0, @writer_pid)
      true
    rescue Errno::ESRCH
      false
    end
  end

  # The writer is a child of this process; a stop that returns without a
  # wait would leave a zombie for the cluster to reap, and TERM to a writer
  # mid-batch is answered by its own trap, which finishes the batch first.

  # For a restart: stop the writer and mark the cluster as not booted, so the
  # supervisor spawns a fresh one once after_booted fires again.
  def restart_writer
    @booted = false
    stop_writer
  end

  # after_stopped fires once the workers are gone (cluster) or the server
  # has stopped accepting (single), so their batches are already through.
  # This process's own reporter (its process and health records) is flushed
  # before the writer goes, not by the at_exit that runs after it. Puma
  # fires this from inside its SIGTERM trap, where a Mutex cannot be taken,
  # so the flush runs on a thread and is waited for.
  def shutdown_writer
    @shutting_down = true
    if ::Railwatch.enabled? && ::Railwatch.config.local?
      Thread.new { ::Railwatch.reporter.shutdown }.join(::Railwatch.config.shutdown_timeout + 1)
    end
    stop_writer
  end

  def stop_writer
    return unless @writer_pid

    Process.kill(:TERM, @writer_pid)
    Process.wait(@writer_pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  ensure
    @writer_pid = nil
  end

  def log(message)
    log_writer.log(message)
  end
end
