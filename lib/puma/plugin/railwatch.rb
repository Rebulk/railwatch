# frozen_string_literal: true

require "puma/plugin"

# `plugin :railwatch` in config/puma.rb. In embedded mode, forks one
# Railwatch::Writer from the Puma master once it has booted, restarts it if
# it dies, and stops it with Puma. Same shape as Solid Queue's
# `solid_queue_mode :fork`. A no-op when Railwatch is off or the transport
# is not :local, so it is safe to leave in place.
#
# Cluster mode only, on purpose. In single mode Puma's request threads are
# already running when after_booted fires, and forking a whole Rails process
# from a multithreaded parent inherits whatever locks those threads hold at
# that instant. A single-mode server writes its own batches, which is the
# path it always had.
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
    unless launcher.options[:workers].to_i.positive?
      log "Railwatch writer not started: Puma is in single mode (set workers > 0). Batches are written in-process."
      return
    end

    # The workers fork from this process after start; they inherit this flag
    # and so retain batches while the writer is starting rather than writing
    # them in-process (Transport::Socket).
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

  # For a restart: stop the writer and mark the cluster as not booted, so the
  # supervisor spawns a fresh one once after_booted fires again.
  def restart_writer
    @booted = false
    stop_writer
  end

  def shutdown_writer
    @shutting_down = true
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
