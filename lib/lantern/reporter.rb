# frozen_string_literal: true

module Lantern
  # One background thread per process. Drains the buffer every flush_interval
  # seconds or when the buffer crosses flush_threshold, and posts to the
  # platform. Re-armed after fork so Puma cluster workers and Solid Queue
  # forked workers each get their own thread. Nothing here touches the app
  # database.
  class Reporter
    INITIAL_RETRY_DELAY = 1.0
    MAX_RETRY_DELAY = 60.0
    DeliveryBatch = Data.define(:id, :records, :dropped, :prepared)

    class DeliveryError < StandardError
      attr_reader :status, :records, :dropped

      def initialize(message, status: nil, records: 0, dropped: 0)
        @status = status
        @records = records
        @dropped = dropped
        super(message)
      end
    end

    # Prepended onto Process's singleton class by the engine. The reset runs
    # before the child returns from fork, so no app or at_exit path can touch
    # the inherited parent buffer first.
    module ForkHook
      def _fork
        pid = super
        Lantern.restart_after_fork! if pid.zero?
        pid
      end
    end

    def initialize(config, transport: nil, random: Random)
      @config = config
      @buffer = Buffer.new(config.buffer_size)
      @transport = transport || Transport::Http.new(config)
      @random = random
      @mutex = Mutex.new
      @flush_mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @pid = Process.pid
      @stopping = false
      @flush_requested = false
      @retry_attempt = 0
      @retry_at = nil
      @retry_batch = nil
      @in_flight_records = 0
      @in_flight_dropped = 0
      @shutdown_notified = false
    end

    def buffer
      ensure_process!
      @buffer
    end

    def write(record)
      ensure_process!
      size = @buffer.push(record)
      arm_thread unless @thread&.alive?
      request_flush if size >= @config.flush_threshold
    end

    # Wake the reporter immediately for unhandled exceptions without doing
    # network I/O on the application thread.
    def write_now(record)
      ensure_process!
      @buffer.push(record)
      arm_thread unless @thread&.alive?
      request_flush
    end

    def flush
      ensure_process!
      @flush_mutex.synchronize { deliver_buffer }
    end

    def ensure_thread
      ensure_process!
      arm_thread unless @thread&.alive?
    end

    # Only valid in a forked child. It deliberately never acquires an
    # inherited lock: another parent thread may have owned that mutex at the
    # instant of fork, and its owner does not exist in the child.
    def restart_after_fork!
      return if @pid == Process.pid

      @pid = Process.pid
      @buffer = Buffer.new(@config.buffer_size)
      @transport = forked_transport
      @mutex = Mutex.new
      @flush_mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @stopping = false
      @flush_requested = false
      @retry_attempt = 0
      @retry_at = nil
      # Newer reporters retain an immutable delivery batch (including its
      # idempotency key) between attempts. Keep this reset forward-compatible
      # so that batch can never cross a process boundary after fork.
      @retry_batch = nil
      @in_flight_records = 0
      @in_flight_dropped = 0
      @shutdown_notified = false
      remove_instance_variable(:@shutdown_deadline) if defined?(@shutdown_deadline)
      self
    end

    def shutdown
      ensure_process!
      ensure_thread if pending_records? && !@thread&.alive?
      thread = @thread
      return unless thread

      timeout = [ @config.shutdown_timeout.to_f, 0.0 ].max
      deadline = Clock.monotonic + timeout
      @mutex.synchronize do
        @stopping = true
        @shutdown_deadline = deadline
        @wakeup.broadcast
      end
      thread.join(timeout) unless thread == Thread.current
      if thread.alive?
        notify_unsent("shutdown timed out")
      else
        notify_unsent("shutdown completed")
      end
    rescue StandardError => e
      Lantern.debug { "shutdown flush failed: #{e.class}: #{e.message}" }
      Lantern.notify_unrecoverable(e)
    end

    private

    def ensure_process!
      restart_after_fork! if @pid != Process.pid
    end

    def arm_thread
      @mutex.synchronize do
        return if @thread&.alive?

        @stopping = false
        @shutdown_notified = false
        @thread = Thread.new { run }
        @thread.name = "lantern-reporter"
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    def forked_transport
      transport = @transport.dup
      transport.reset_after_fork! if transport.respond_to?(:reset_after_fork!)
      transport
    rescue TypeError
      @transport.tap { |object| object.reset_after_fork! if object.respond_to?(:reset_after_fork!) }
    end

    def request_flush
      @mutex.synchronize do
        @flush_requested = true
        @wakeup.signal
      end
    end

    def run
      loop do
        action = wait_for_work
        if action == :shutdown
          flush_for_shutdown
          break
        end

        begin
          flush
        rescue StandardError => e
          Lantern.debug { "flush error: #{e.class}: #{e.message}" }
          Lantern.notify_unrecoverable(e)
        end
      end
    end

    def wait_for_work
      @mutex.synchronize do
        interval_deadline = Clock.monotonic + @config.flush_interval
        loop do
          return :shutdown if @stopping

          now = Clock.monotonic
          if @retry_at
            return :flush if now >= @retry_at
            deadline = @retry_at
          else
            if @flush_requested
              @flush_requested = false
              return :flush
            end
            return :flush if now >= interval_deadline
            deadline = interval_deadline
          end
          @wakeup.wait(@mutex, [ deadline - now, 0.0 ].max)
        end
      end
    end

    def deliver_buffer
      # A 401 was reported once, when the transport first saw it; after
      # that the token is wrong until the process restarts, and repeating
      # the callback every flush would be a self-sustaining error source in
      # an app that turns on_unrecoverable into an error report.
      return discard_unauthorized if @transport.respond_to?(:unauthorized?) && @transport.unauthorized?

      batch = drain_into_flight
      if batch.records.empty?
        delivery_succeeded
        return
      end

      deliverable = batch.prepared ? batch.records : Lantern.run_before_ingest(batch.records)
      if deliverable.empty?
        delivery_succeeded
        return
      end
      batch = DeliveryBatch.new(id: batch.id, records: deliverable, dropped: batch.dropped, prepared: true)

      result = deliver(batch)
      Lantern.debug { "flushed #{deliverable.size} records (dropped #{batch.dropped}): #{result.to_h}" }
      if result.ok
        delivery_succeeded
      elsif retryable?(result)
        retain(batch, result)
      else
        delivery_rejected(batch, result)
      end
      result
    rescue StandardError => e
      result = Transport::Http::Result.new(ok: false, error: "#{e.class}: #{e.message}")
      batch&.records&.any? ? retain(batch, result) : delivery_succeeded
      Lantern.notify_unrecoverable(e)
      result
    ensure
      in_flight(0, 0)
    end

    def retryable?(result)
      return result.retryable? if result.respond_to?(:retryable?)

      !result.ok && Transport::Http.retryable_status?(result.status)
    end

    def retain(batch, result)
      @mutex.synchronize do
        @retry_batch = batch
        @in_flight_records = 0
        @in_flight_dropped = 0
        @retry_attempt += 1
        delay = retry_delay(@retry_attempt)
        @retry_at = Clock.monotonic + delay
        @wakeup.signal
        Lantern.debug do
          "retained #{batch.records.size} records after retryable delivery failure " \
            "(#{result.error || result.status}); retry #{@retry_attempt} in #{delay.round(3)}s"
        end
      end
    end

    def discard_unauthorized
      batch = drain_into_flight
      delivery_succeeded
      Lantern.debug { "transport unauthorized; discarded #{batch.records.size} records (dropped #{batch.dropped})" } unless batch.records.empty?
      nil
    end

    def delivery_succeeded
      @mutex.synchronize do
        @in_flight_records = 0
        @in_flight_dropped = 0
        @retry_attempt = 0
        @retry_at = nil
      end
    end

    def delivery_rejected(batch, result)
      delivery_succeeded
      detail = result.error.to_s.empty? ? "HTTP #{result.status}" : result.error
      Lantern.notify_unrecoverable(
        DeliveryError.new("Lantern ingest permanently rejected #{batch.records.size} records: #{detail}",
                          status: result.status, records: batch.records.size, dropped: batch.dropped)
      )
    end

    # Equal jitter keeps a non-zero floor (no busy loop) while spreading
    # reporters between 50% and 100% of each exponential window.
    def retry_delay(attempt)
      exponent = [ attempt - 1, 6 ].min
      ceiling = [ INITIAL_RETRY_DELAY * (2**exponent), MAX_RETRY_DELAY ].min
      ceiling * (0.5 + @random.rand * 0.5)
    end

    def drain_into_flight
      @mutex.synchronize do
        batch = @retry_batch
        @retry_batch = nil
        unless batch
          records, dropped = @buffer.drain
          batch = DeliveryBatch.new(id: SecureRandom.uuid, records: records, dropped: dropped, prepared: false)
        end
        @in_flight_records = batch.records.size
        @in_flight_dropped = batch.dropped
        batch
      end
    end

    # Third-party/test transports written before batch idempotency only accept
    # `dropped:`. Keep those working while the HTTP transport receives the
    # stable identity required to replay a request safely.
    def deliver(batch)
      parameters = @transport.method(:deliver).parameters
      accepts_batch_id = parameters.any? { |kind, name| kind == :keyrest || name == :batch_id }
      keywords = { dropped: batch.dropped }
      keywords[:batch_id] = batch.id if accepts_batch_id
      @transport.deliver(batch.records, **keywords)
    end

    def in_flight(records, dropped)
      @mutex.synchronize do
        @in_flight_records = records
        @in_flight_dropped = dropped
      end
    end

    def flush_for_shutdown
      deadline = @mutex.synchronize { @shutdown_deadline }
      loop do
        flush if pending_records?
        break unless pending_records?

        now = Clock.monotonic
        break if now >= deadline

        retry_at = @mutex.synchronize { @retry_at }
        wait_until([ retry_at || now, deadline ].min)
      end
      notify_unsent("shutdown deadline expired") if pending_records?
    end

    def wait_until(deadline)
      @mutex.synchronize do
        while (remaining = deadline - Clock.monotonic).positive?
          @wakeup.wait(@mutex, remaining)
        end
      end
    end

    def notify_unsent(reason)
      records, dropped = pending_delivery
      return if records.zero?

      should_notify = @mutex.synchronize do
        next false if @shutdown_notified
        @shutdown_notified = true
      end
      return unless should_notify

      Lantern.notify_unrecoverable(
        DeliveryError.new("Lantern #{reason} with #{records} unsent records retained in memory",
                          records: records, dropped: dropped)
      )
    end

    def pending_delivery
      @mutex.synchronize do
        buffered, dropped = @buffer.stats
        retry_records = @retry_batch&.records&.size || 0
        retry_dropped = @retry_batch&.dropped || 0
        [ buffered + retry_records + @in_flight_records, dropped + retry_dropped + @in_flight_dropped ]
      end
    end

    def pending_records?
      pending_delivery.first.positive?
    end
  end
end
