# frozen_string_literal: true

module Railwatch
  module Export
    # One thread per process, draining the queue to the receiver.
    #
    # Every eligible process runs one; the lease decides which actually sends,
    # so there is no separate supervisor to keep alive and no dependence on
    # the writer being up. A process that loses the lease keeps polling and
    # takes over within its TTL if the holder disappears.
    #
    # Nothing here holds a database connection across an HTTP request: the
    # claim commits, the request happens, the outcome commits. That is the
    # whole reason the queue exists rather than sending inline.
    module Sender
      ROLES = %w[web worker writer].freeze
      IDLE = 5
      # An application process waits before its first attempt so the writer,
      # which is the natural holder, gets the lease in the ordinary case.
      FIRST_ATTEMPT_DELAY = 5

      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @pid = nil
      @stopping = false
      @owner = nil

      module_function

      def start!
        return unless Railwatch.enabled? && Railwatch.config.export?
        return if defined?(Rails) && Rails.env.test?
        return unless ROLES.include?(Subscribers::ProcessInfo.role)
        return if @thread&.alive? && @pid == Process.pid

        @mutex.synchronize do
          return if @thread&.alive? && @pid == Process.pid

          @pid = Process.pid
          @stopping = false
          # Per process, not per database: it is this process's claim on the
          # lease, and a forked child must never inherit its parent's.
          @owner = SecureRandom.uuid
          @thread = Thread.new { run }
          @thread.name = "railwatch-export"
          @thread.abort_on_exception = false
          @thread.report_on_exception = false
        end
      end

      # A forked child inherits a dead thread and possibly a mutex held by a
      # vanished one. It must not inherit the parent's lease claim either: the
      # parent may still be sending under it.
      def restart_after_fork!
        @mutex = Mutex.new
        @wakeup = ConditionVariable.new
        @thread = nil
        @pid = nil
        @stopping = false
        @owner = nil
        @client = nil
        start!
      end

      def stop!
        return unless @thread

        @stopping = true
        @mutex.synchronize { @wakeup.signal }
        # Only forget the thread if it actually stopped. Dropping the handle
        # on a thread still inside a request would let a later start! run a
        # second loop under the same owner, both claiming rows.
        @thread = nil if @thread.join(Railwatch.config.shutdown_timeout)
      end

      # Something was queued; look now rather than at the next tick.
      def wake!
        @mutex.synchronize { @wakeup.signal }
      end

      def run
        wait(FIRST_ATTEMPT_DELAY)
        until @stopping
          sent = drain_one
          wait(IDLE) unless sent || @stopping
        end
        release_lease
      end

      # Hand the lease back rather than making the next process wait out its
      # TTL for a holder that has politely finished.
      def release_lease
        Railwatch.internal do
          environment = Environment.current
          outbox = Outbox.new(Railwatch.config, environment)
          environment.with_telemetry { outbox.release_lease!(owner: @owner) }
        end
      rescue StandardError => e
        Railwatch.debug { "export sender: releasing lease failed: #{e.class}" }
      end

      def wait(seconds)
        @mutex.synchronize { @wakeup.wait(@mutex, seconds) unless @stopping }
      end

      # One delivery, start to finish. Returns true when there may be more.
      def drain_one
        Railwatch.internal do
          environment = Environment.current
          outbox = Outbox.new(Railwatch.config, environment)
          claim = environment.with_telemetry { outbox.claim!(owner: @owner) } or return false

          outcome = client.deliver(claim, producer_id: claim.producer_id)
          environment.with_telemetry { outbox.finish!(claim, outcome) }
          true
        end
      rescue StandardError => e
        # The queue is durable: whatever went wrong here, the delivery is
        # still there and its claim expires. Never take the thread down.
        Railwatch.debug { "export sender: #{e.class}: #{e.message}" }
        false
      end

      def client
        @client ||= Client.new(Railwatch.config)
      end
    end
  end
end
