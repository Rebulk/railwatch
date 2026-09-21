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
#
# Nothing in `start` may touch Railwatch: `bundle exec puma` fires plugin
# starts BEFORE it loads the Rack app, so the constant may not exist yet.
# Every decision that needs the app is made from the background supervisor,
# which waits for after_booted.
Puma::Plugin.create do
  attr_reader :log_writer, :writer_pid

  POLL = 2
  # How often a stopping writer is checked for, and how long a KILL is given
  # to take before the pid is abandoned (a process stuck in disk I/O cannot
  # die until the I/O returns, and Puma's exit should not wait for that).
  REAP_POLL = 0.05
  KILL_REAP = 1

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$
    @launcher = launcher
    @shutting_down = false
    @booted = false
    @warned = false

    # When the app is already loaded (`bin/rails server` loads it before
    # handing over to Puma), mark a writer expected now: cluster workers fork
    # from this process after start and inherit the flag, so they retain
    # batches while the writer is starting instead of writing them in-process.
    # Under bare `puma` this is false and the workers find the writer on
    # their transport's next re-check instead (Transport::Socket).
    ::Railwatch::Writer.expected! if active?

    # in_background blocks are collected at plugin start and started by the
    # runner once, so this has to be registered here, not from after_booted
    # (by then they have already been fired and a late block never runs). It
    # waits for boot itself.
    in_background { supervise }

    launcher.events.after_booted { booted! }
    # A phased restart fires before_restart and then, once the new workers
    # are up, after_booted again. The writer is stopped for the restart and
    # the supervisor, which is still running, respawns it when @booted flips
    # back. Only a real stop latches shutdown.
    launcher.events.before_restart { restart_writer }
    # after_stopped only latches. It is NOT where the writer is stopped:
    # Puma's SIGTERM trap fires it BEFORE `stop_blocked` drains in-flight
    # requests, so stopping here would take the writer away from requests
    # that are still running. at_exit runs after the whole run loop.
    launcher.events.after_stopped { @shutting_down = true }
    at_exit { shutdown_writer if Process.pid == @puma_pid }
  end

  private

  def booted!
    @booted = true
    ::Railwatch::Writer.expected! if active?
  end

  # Whether this process should run a writer. Answered fresh each time, and
  # safe before the app is loaded: `defined?(Railwatch)` is true as soon as
  # the gem's entrypoint has been required (Bundler.require), but a bare
  # `puma` on an app that has not required it yet sees neither, and must not
  # raise out of Puma's boot.
  def active?
    return false unless defined?(::Railwatch) && ::Railwatch.respond_to?(:enabled?)
    return false unless ::Railwatch.enabled? && ::Railwatch.config.local?

    path = ::Railwatch.config.writer_socket_path
    return false if path.nil?
    return true if ::Railwatch::Writer.usable_path?(path)

    unless @warned
      @warned = true
      log "Railwatch writer not started: socket path #{path} is #{path.bytesize} bytes, over the " \
          "#{::Railwatch::Writer::MAX_SOCKET_PATH}-byte limit; set RAILWATCH_WRITER_SOCKET to a shorter path. " \
          "Batches are written in-process meanwhile."
    end
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
      next unless @booted && active?
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

  # For a restart: stop the writer and mark the cluster as not booted, so the
  # supervisor spawns a fresh one once after_booted fires again.
  def restart_writer
    @booted = false
    stop_writer
  end

  # Runs from at_exit, after Puma's run loop has returned and every request
  # has been served, in both single and cluster mode. Flushes this process's
  # own reporter (its process and health records, and in single mode the
  # requests' records) while the writer is still listening, then stops it.
  def shutdown_writer
    @shutting_down = true
    if defined?(::Railwatch) && ::Railwatch.respond_to?(:enabled?) && ::Railwatch.enabled? && ::Railwatch.config.local?
      ::Railwatch.reporter.shutdown
    end
    stop_writer
  rescue StandardError => e
    log "Railwatch writer shutdown failed (#{e.class}: #{e.message})"
  end

  # TERM closes the writer's listener; it finishes what it is holding and
  # exits on its own. Waited for with a deadline, not Process.wait, which
  # has none: a writer wedged in a SQLite write or on a full disk would hold
  # Puma's exit open for as long as it stayed wedged. KILL past the deadline.
  # Reaped either way, so a cluster master never leaves a zombie behind.
  def stop_writer
    return unless @writer_pid

    Process.kill(:TERM, @writer_pid)
    return if reaped_within?(stop_timeout)

    log "Railwatch writer (pid #{@writer_pid}) did not exit within #{stop_timeout}s of TERM; killing it"
    Process.kill(:KILL, @writer_pid)
    log "Railwatch writer (pid #{@writer_pid}) did not exit on KILL; leaving it" unless reaped_within?(KILL_REAP)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  ensure
    @writer_pid = nil
  end

  # shutdown_timeout: the same allowance this process gives its own
  # reporter, and deliberately NOT the writer's full theoretical exit time
  # (a sequential SHUTDOWN_DRAIN join per worker thread, its maintenance
  # join, then its own reporter shutdown -- 13s at the defaults). Two
  # reasons. This runs from at_exit inside the container's stop grace, which
  # under Kamal with its proxy is Docker's default 10s from TERM to KILL,
  # and the reporter shutdown that precedes this has already spent up to
  # shutdown_timeout of it. And a writer killed mid-batch loses nothing:
  # the transaction rolls back and the worker retries the batch by id
  # against the next writer (Writer#serve says so), so waiting longer buys
  # no data, only exit time. An idle writer is gone in well under a second.
  def stop_timeout
    [ ::Railwatch.config.shutdown_timeout.to_f, 0.0 ].max
  end

  # Non-blocking waits on a short poll; Process.wait has no timeout and a
  # child that never exits would hold it forever. ECHILD (the cluster's
  # wait2(-1) reaped it first) propagates to stop_writer, which reads it as
  # gone.
  def reaped_within?(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return true if Process.waitpid(@writer_pid, Process::WNOHANG)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep REAP_POLL
    end
  end

  def log(message)
    log_writer.log(message)
  end
end
