# frozen_string_literal: true

require "puma/plugin"

# `plugin :railwatch` in config/puma.rb. In embedded mode, forks one
# Railwatch::Writer from the Puma master once it has booted, restarts it if
# it dies, and stops it with Puma. Same shape as Solid Queue's
# `solid_queue_mode :fork`. A no-op when Railwatch is off or the transport
# is not :local, so it is safe to leave in place.
Puma::Plugin.create do
  attr_reader :log_writer, :writer_pid

  POLL = 2

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$
    @stopping = false
    @booted = false

    # in_background blocks are collected at plugin start and started by the
    # cluster once, so this has to be registered here, not from after_booted
    # (by then the cluster has already fired them and a late block never
    # runs). It waits for boot itself.
    in_background { supervise }

    launcher.events.after_booted { @booted = true }
    launcher.events.after_stopped { stop_writer }
    launcher.events.before_restart { stop_writer }
  end

  private

  def active?
    defined?(::Railwatch) && ::Railwatch.enabled? && ::Railwatch.config.local? && ::Railwatch.config.writer_socket_path
  end

  def spawn_writer
    @writer_pid = fork do
      # The child inherits the master's reporter, threads and connections;
      # reset all of it before doing anything, as every forked child does.
      ::Railwatch.restart_after_fork!
      ::Railwatch::Writer.run!(parent: @puma_pid)
      exit!(0)
    end
    log "Railwatch writer started (pid #{@writer_pid})"
  end

  # Puma's cluster reaps every child with wait2(-1), the writer included, so
  # waitpid on the writer's pid raises ECHILD after it has died. Liveness is
  # asked with signal 0 instead, which works whoever reaped it.
  def supervise
    sleep POLL until @booted || @stopping
    return if @stopping || !active?

    spawn_writer
    loop do
      sleep POLL
      break if @stopping
      next if writer_alive?

      log "Railwatch writer (pid #{@writer_pid}) is gone; restarting"
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

  def stop_writer
    @stopping = true
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
