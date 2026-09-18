# frozen_string_literal: true

module Railwatch
  # One background thread per process. Drains the buffer every flush_interval
  # seconds or when the buffer crosses flush_threshold, and posts to the
  # platform. Re-armed after fork so Puma cluster workers and Solid Queue
  # forked workers each get their own thread. Nothing here touches the app
  # database.
  class Reporter
    INITIAL_RETRY_DELAY = 1.0
    MAX_RETRY_DELAY = 60.0
    # A retained batch is retried this many times, then dropped (and
    # counted) so the buffer's newest records win again. Without the cap a
    # batch that keeps failing would be pinned forever while everything
    # newer was discarded around it. Eight attempts on the backoff ladder is
    # roughly four minutes of outage.
    MAX_RETRY_ATTEMPTS = 8
    # An unhandled exception asks for an immediate flush so it reaches the
    # platform without waiting out flush_interval. "Immediate" is this many
    # seconds, not zero: during an exception storm every request would
    # otherwise wake the thread for a handful of records, and a burst that
    # produced 4,000 records went out as 400 POSTs of ten. A lone exception
    # still ships within the window; a storm coalesces into full batches.
    URGENT_FLUSH_DELAY = 0.25
    # Three pressure ticks reach 8x and three clear ticks recover to 1x. That
    # is enough to turn a saturated stream into breathing room without the
    # long recovery and sparse telemetry a 16x cap would impose.
    MAX_BACKPRESSURE_FACTOR = 8.0
    DeliveryBatch = Data.define(:id, :records, :bytes, :dropped, :dropped_bytes, :prepared)

    class DeliveryError < StandardError
      attr_reader :status, :records, :bytes, :dropped, :dropped_bytes

      def initialize(message, status: nil, records: 0, bytes: 0, dropped: 0, dropped_bytes: 0)
        @status = status
        @records = records
        @bytes = bytes
        @dropped = dropped
        @dropped_bytes = dropped_bytes
        super(message)
      end
    end

    def initialize(config, transport: nil, random: Random)
      @config = config
      @buffer = build_buffer
      @transport = transport || Transport::Http.new(config)
      @random = random
      @mutex = Mutex.new
      @flush_mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @pid = Process.pid
      @stopping = false
      @flush_requested = false
      @urgent_at = nil
      @retry_attempt = 0
      @retry_at = nil
      @retry_batch = nil
      # Ruby ivars hold object references atomically. The reporter is the
      # only writer, and sampler readers can safely tolerate one stale Float,
      # so the hot execution path does not take a mutex for this value.
      @backpressure_factor = 1.0
      @in_flight_records = 0
      @in_flight_dropped = 0
      @in_flight_bytes = 0
      @in_flight_dropped_bytes = 0
      @shutdown_notified = false
    end

    def buffer
      ensure_process!
      @buffer
    end

    attr_reader :backpressure_factor

    def write(record, bytes = nil)
      ensure_process!
      size = @buffer.push(record, bytes)
      arm_thread unless @thread&.alive?
      request_flush if size >= @config.flush_threshold
    end

    # Wake the reporter immediately for unhandled exceptions without doing
    # network I/O on the application thread.
    def write_now(record)
      ensure_process!
      size = @buffer.push(record)
      arm_thread unless @thread&.alive?
      # A full buffer flushes now regardless; anything smaller flushes at
      # the end of the urgent window, however many exceptions land in it.
      return request_flush if size >= @config.flush_threshold

      @mutex.synchronize do
        @urgent_at ||= Clock.monotonic + URGENT_FLUSH_DELAY
        @wakeup.signal
      end
    end

    def flush
      ensure_process!
      @flush_mutex.synchronize do
        update_backpressure
        deliver_buffer
      end
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
      @buffer = build_buffer
      @transport = forked_transport
      @mutex = Mutex.new
      @flush_mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @stopping = false
      @flush_requested = false
      @urgent_at = nil
      @retry_attempt = 0
      @retry_at = nil
      # Newer reporters retain an immutable delivery batch (including its
      # idempotency key) between attempts. Keep this reset forward-compatible
      # so that batch can never cross a process boundary after fork.
      @retry_batch = nil
      @backpressure_factor = 1.0
      @in_flight_records = 0
      @in_flight_dropped = 0
      @in_flight_bytes = 0
      @in_flight_dropped_bytes = 0
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
      Railwatch.debug { "shutdown flush failed: #{e.class}: #{e.message}" }
      Railwatch.notify_unrecoverable(e)
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
        @thread.name = "railwatch-reporter"
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    def forked_transport
      # A child may be a different kind of process from its parent: the
      # writer forked from a Puma master must write SQLite itself, not hand
      # batches back to the socket it is about to serve.
      reselected = Railwatch.local_transport if @config.local?
      return reselected if reselected && reselected.class != @transport.class

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
          Railwatch.debug { "flush error: #{e.class}: #{e.message}" }
          Railwatch.notify_unrecoverable(e)
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
              @urgent_at = nil
              return :flush
            end
            if @urgent_at && now >= @urgent_at
              @urgent_at = nil
              return :flush
            end
            return :flush if now >= interval_deadline
            deadline = [ interval_deadline, @urgent_at ].compact.min
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

      unless batch.prepared
        deliverable = Railwatch.run_before_ingest(batch.records)
        if deliverable.empty?
          @buffer.account_dropped(batch.dropped, bytes: batch.dropped_bytes) if batch.dropped.positive?
          delivery_succeeded
          return
        end
        # A before_ingest hook can rewrite records, so their measured weights
        # no longer describe them. Re-bound only then; without hooks the
        # batch is already inside batch_bytes from drain_into_flight.
        batch = if deliverable.equal?(batch.records)
          DeliveryBatch.new(**batch.to_h, prepared: true)
        else
          rebound(batch, deliverable)
        end
        if batch.records.empty?
          @buffer.account_dropped(batch.dropped, bytes: batch.dropped_bytes)
          delivery_succeeded
          return
        end
      end

      result = deliver(batch)
      Railwatch.debug do
        "flushed #{batch.records.size} records/#{batch.bytes} bytes " \
          "(dropped #{batch.dropped}/#{batch.dropped_bytes} bytes): #{result.to_h}"
      end
      if result.ok
        # Per-record rejection is routine and documented (an unsupported
        # record kind, a record the environment does not retain). Cloud's
        # ingest batch is the authoritative accounting for it; re-reporting it
        # through on_unrecoverable would page an operator for normal traffic.
        Railwatch.debug { "ingest rejected #{result.rejected} of #{deliverable.size} records" } if result.rejected.to_i.positive?
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
      Railwatch.notify_unrecoverable(e)
      result
    ensure
      in_flight(0, 0, 0, 0)
    end

    def retryable?(result)
      return result.retryable? if result.respond_to?(:retryable?)

      !result.ok && Transport::Http.retryable_status?(result.status)
    end

    def retain(batch, result)
      @mutex.synchronize do
        @in_flight_records = 0
        @in_flight_dropped = 0
        @in_flight_bytes = 0
        @in_flight_dropped_bytes = 0
        @retry_attempt += 1
        if @retry_attempt > MAX_RETRY_ATTEMPTS
          @buffer.account_dropped(batch.records.size + batch.dropped,
                                  bytes: batch.bytes + batch.dropped_bytes)
          @retry_attempt = 0
          @retry_at = nil
          Railwatch.debug { "gave up on a batch of #{batch.records.size} records after #{MAX_RETRY_ATTEMPTS} retries (#{result.error || result.status}); dropped and counted" }
          # Losing a batch is not a debug-level event: with an ingest (or an
          # embedded writer) that never comes back this is the only place the
          # loss is ever reported, and the dropped counter it leaves behind
          # rides on the NEXT successful delivery, which may never happen.
          Railwatch.notify_unrecoverable(
            DeliveryError.new("Railwatch dropped #{batch.records.size} records after #{MAX_RETRY_ATTEMPTS} failed delivery attempts: " \
                              "#{result.error || result.status}",
                              status: result.status, records: batch.records.size, bytes: batch.bytes,
                              dropped: batch.dropped, dropped_bytes: batch.dropped_bytes)
          )
          next
        end
        @retry_batch = batch
        delay = retry_delay(@retry_attempt)
        @retry_at = Clock.monotonic + delay
        @wakeup.signal
        Railwatch.debug do
          "retained #{batch.records.size} records after retryable delivery failure " \
            "(#{result.error || result.status}); retry #{@retry_attempt} in #{delay.round(3)}s"
        end
      end
    end

    def discard_unauthorized
      batch = drain_into_flight
      delivery_succeeded
      Railwatch.debug { "transport unauthorized; discarded #{batch.records.size} records (dropped #{batch.dropped})" } unless batch.records.empty?
      nil
    end

    def delivery_succeeded
      @mutex.synchronize do
        @in_flight_records = 0
        @in_flight_dropped = 0
        @in_flight_bytes = 0
        @in_flight_dropped_bytes = 0
        @retry_attempt = 0
        @retry_at = nil
      end
    end

    def delivery_rejected(batch, result)
      delivery_succeeded
      detail = result.error.to_s.empty? ? "HTTP #{result.status}" : result.error
      Railwatch.notify_unrecoverable(
        DeliveryError.new("Railwatch ingest permanently rejected #{batch.records.size} records: #{detail}",
                          status: result.status, records: batch.records.size, bytes: batch.bytes,
                          dropped: batch.dropped, dropped_bytes: batch.dropped_bytes)
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
      batch = @mutex.synchronize do
        retry_batch = @retry_batch
        @retry_batch = nil
        next drained_batch unless retry_batch

        retry_batch
      end
      in_flight(batch.records.size, batch.dropped, batch.bytes, batch.dropped_bytes)
      batch
    end

    # Called with the mutex held. One delivery is capped at batch_bytes while
    # the queue holds up to buffer_bytes, so a full queue can be more than one
    # POST. The split uses the weights measured when the records were pushed
    # -- nothing is weighed twice -- and the tail goes back on the queue for
    # the next flush instead of being dropped.
    def drained_batch
      records, dropped, dropped_bytes, sizes = @buffer.drain
      cut = records.size
      bytes = 0
      sizes.each_with_index do |size, index|
        # index.positive? so a single record heavier than batch_bytes still
        # goes out on its own rather than deferring forever; the transport
        # drops it there, once, and counts it.
        if index.positive? && bytes + size > @config.batch_bytes
          cut = index
          break
        end
        bytes += size
      end
      if cut < records.size
        @buffer.restore(records[cut..], sizes[cut..])
        records = records[0, cut]
      end
      DeliveryBatch.new(id: SecureRandom.uuid, records: records, bytes: bytes,
                        dropped: dropped, dropped_bytes: dropped_bytes, prepared: false)
    end

    # A before_ingest hook returned different records; weigh them again and
    # drop whatever no longer fits in one delivery.
    def rebound(batch, deliverable)
      kept = []
      bytes = 0
      dropped = 0
      dropped_bytes = 0
      deliverable.each do |record|
        record_bytes = Record.buffered_bytes(record, limit: @config.batch_bytes)
        if kept.any? && bytes + record_bytes > @config.batch_bytes || record_bytes > @config.batch_bytes
          dropped += 1
          dropped_bytes += record_bytes
        else
          kept << record
          bytes += record_bytes
        end
      end
      DeliveryBatch.new(id: batch.id, records: kept, bytes: bytes, dropped: batch.dropped + dropped,
                        dropped_bytes: batch.dropped_bytes + dropped_bytes, prepared: true)
    end

    # Third-party/test transports written before batch idempotency only accept
    # `dropped:`. Keep those working while the HTTP transport receives the
    # stable identity required to replay a request safely.
    def deliver(batch)
      parameters = @transport.method(:deliver).parameters
      accepts_batch_id = parameters.any? { |kind, name| kind == :keyrest || name == :batch_id }
      accepts_dropped_bytes = parameters.any? { |kind, name| kind == :keyrest || name == :dropped_bytes }
      accepts_backpressure = parameters.any? { |kind, name| kind == :keyrest || name == :backpressure_factor }
      keywords = { dropped: batch.dropped }
      keywords[:batch_id] = batch.id if accepts_batch_id
      keywords[:dropped_bytes] = batch.dropped_bytes if accepts_dropped_bytes
      keywords[:backpressure_factor] = @backpressure_factor if accepts_backpressure
      @transport.deliver(batch.records, **keywords)
    end

    def update_backpressure
      unless @config.backpressure
        @backpressure_factor = 1.0
        return
      end

      buffered, _, buffered_bytes, = @buffer.stats
      high_water = @config.backpressure_high_water
      pressured = buffered >= @config.buffer_size * high_water ||
        buffered_bytes >= @config.buffer_bytes * high_water || @retry_attempt.positive?
      @backpressure_factor = if pressured
        [ @backpressure_factor * 2.0, MAX_BACKPRESSURE_FACTOR ].min
      else
        [ @backpressure_factor / 2.0, 1.0 ].max
      end
    end

    def in_flight(records, dropped, bytes, dropped_bytes)
      @mutex.synchronize do
        @in_flight_records = records
        @in_flight_dropped = dropped
        @in_flight_bytes = bytes
        @in_flight_dropped_bytes = dropped_bytes
      end
    end

    def build_buffer
      Buffer.new(@config.buffer_size, byte_capacity: @config.buffer_bytes)
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
      records, dropped, bytes, dropped_bytes = pending_delivery
      return if records.zero?

      should_notify = @mutex.synchronize do
        next false if @shutdown_notified
        @shutdown_notified = true
      end
      return unless should_notify

      Railwatch.notify_unrecoverable(
        DeliveryError.new("Railwatch #{reason} with #{records} unsent records retained in memory (#{bytes} bytes)",
                          records: records, bytes: bytes, dropped: dropped, dropped_bytes: dropped_bytes)
      )
    end

    def pending_delivery
      @mutex.synchronize do
        buffered, dropped, buffered_bytes, buffer_dropped_bytes = @buffer.stats
        retry_records = @retry_batch&.records&.size || 0
        retry_dropped = @retry_batch&.dropped || 0
        [ buffered + retry_records + @in_flight_records,
          dropped + retry_dropped + @in_flight_dropped,
          buffered_bytes + (@retry_batch&.bytes || 0) + @in_flight_bytes,
          buffer_dropped_bytes + (@retry_batch&.dropped_bytes || 0) + @in_flight_dropped_bytes ]
      end
    end

    def pending_records?
      pending_delivery.first.positive?
    end
  end
end
