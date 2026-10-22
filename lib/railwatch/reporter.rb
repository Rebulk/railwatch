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
    # roughly four minutes of outage; one to two when every attempt is
    # refused with a Retry-After (MAX_REFUSED_RETRY_DELAY).
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
    # A receiver that answers with a Retry-After (503 "disk almost full" or
    # "database busy", 429 "rate limit exceeded") is refusing, not failing.
    # The next attempt waits for its Retry-After instead of the ladder, up
    # to this long. Railwatch's receivers send 15 s for a busy database,
    # honoured as given, and 60 s for the disk floor and the rate-limit
    # window, which are not forecasts: the floor is re-checked every 10 s
    # and lifts the moment space is back, and a window can end at any time.
    # The ladder alone was worse than either: a minute into a refusal its
    # rungs were 16-60 s apart, and a recovered app stayed sampled down
    # until the next one. A longer wait is cut to between half and all of
    # this, jittered so processes refused together do not return together:
    # one POST per process every 7.5-15 s.
    MAX_REFUSED_RETRY_DELAY = 15.0
    DeliveryBatch = Data.define(:id, :records, :bytes, :dropped, :dropped_bytes, :prepared)
    # From the first refusal to the next accepted delivery: when it began,
    # what the receiver said, and the loss counters as they stood then.
    Refusal = Struct.new(:started_at, :reason, :overflowed, :sampled_out, :gave_up)

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
      @unreachable = false
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
      @refusal = nil
      @sampled_out = 0
    end

    def buffer
      ensure_process!
      @buffer
    end

    attr_reader :backpressure_factor

    # The sampler calls this for an execution the configured rate kept and
    # backpressure did not. Only reached while the factor is above one.
    def note_sampled_out
      ensure_process!
      @mutex.synchronize { @sampled_out += 1 }
    end

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
      deferred = nil
      result = @flush_mutex.synchronize do
        @deferred_notifications = []
        update_backpressure
        deliver_buffer
      ensure
        deferred = @deferred_notifications
        @deferred_notifications = nil
      end
      deferred&.each { |error| Railwatch.notify_unrecoverable(error) }
      result
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
      @refusal = nil
      @sampled_out = 0
      remove_instance_variable(:@shutdown_deadline) if defined?(@shutdown_deadline)
      self
    end

    # The reporter can be built before the application's own configuration
    # has had its say. A rake process invokes its top-level task -- which is
    # where the command patch starts the execution, and sampling that
    # execution builds the reporter -- before the task's `:environment`
    # prerequisite boots Rails and runs config/initializers. A token in the
    # environment is enough for Railwatch to be enabled that early.
    #
    # Nothing has been recorded at that point -- starting an execution
    # decides sampling and pushes nothing -- so deciding again here is free.
    def adopt_final_config!
      # Sized from the config as it stood, which was the default one. Safe
      # only while the buffer is still empty: resizing means a new buffer,
      # and anything already in the old one would go with it.
      @buffer = build_buffer if @thread.nil? && @buffer.size.zero?
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

    # Everything reachable from deliver_buffer runs inside @flush_mutex, so
    # the loss it reports cannot be handed to the application there. Ruby's
    # Mutex is not reentrant: the documented callback is Rails.error.report,
    # whose subscriber records the error as an exception and can end up asking
    # this same reporter to flush -- "ThreadError: deadlock; recursive
    # locking", rescued by notify_unrecoverable and so a callback cut off
    # halfway, reporting nothing. Collected here and dispatched by flush once
    # the lock is released. retain already does this for @mutex; @flush_mutex
    # is the outer one it still sat inside.
    def defer_notification(error)
      @deferred_notifications ? @deferred_notifications << error : Railwatch.notify_unrecoverable(error)
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
        # batch.records, not the local `deliverable`: that is only assigned on
        # the first attempt, so a retry that succeeds with rejections would
        # raise here and be retained as if it had failed.
        Railwatch.debug { "ingest rejected #{result.rejected} of #{batch.records.size} records" } if result.rejected.to_i.positive?
        delivery_succeeded
        refusal_ended if @refusal
      elsif retryable?(result)
        retain(batch, result)
      else
        delivery_rejected(batch, result)
      end
      result
    rescue StandardError => e
      result = Transport::Http::Result.new(ok: false, error: "#{e.class}: #{e.message}")
      batch&.records&.any? ? retain(batch, result) : delivery_succeeded
      defer_notification(e)
      result
    ensure
      in_flight(0, 0, 0, 0)
    end

    def retryable?(result)
      return result.retryable? if result.respond_to?(:retryable?)

      !result.ok && Transport::Http.retryable_status?(result.status)
    end

    def retain(batch, result)
      refused_until = result.retry_after_at if result.respond_to?(:retry_after_at)
      refusal = nil
      gave_up = @mutex.synchronize do
        @in_flight_records = 0
        @in_flight_dropped = 0
        @in_flight_bytes = 0
        @in_flight_dropped_bytes = 0
        if refused_until && !@refusal
          refusal = @refusal = Refusal.new(started_at: Clock.monotonic, reason: failure_detail(result),
                                           overflowed: @buffer.overflowed, sampled_out: @sampled_out, gave_up: 0)
          # Nothing leaves this buffer until the receiver accepts again, and
          # with retries now seconds apart, so are the flush ticks that would
          # otherwise double the factor up to here. They hold it there.
          @backpressure_factor = MAX_BACKPRESSURE_FACTOR if @config.backpressure
        end
        @retry_attempt += 1
        @unreachable = result.status.nil? && result.error.to_s.start_with?("Errno::ECONNREFUSED")
        if @retry_attempt > MAX_RETRY_ATTEMPTS
          @buffer.account_dropped(batch.records.size + batch.dropped,
                                  bytes: batch.bytes + batch.dropped_bytes)
          @refusal.gave_up += batch.records.size if @refusal
          @retry_attempt = 0
          @retry_at = nil
          Railwatch.debug { "gave up on a batch of #{batch.records.size} records after #{MAX_RETRY_ATTEMPTS} retries (#{result.error || result.status}); dropped and counted" }
          next true
        end
        @retry_batch = batch
        delay = refused_until ? refused_delay(refused_until) : retry_delay(@retry_attempt)
        @retry_at = Clock.monotonic + delay
        @wakeup.signal
        Railwatch.debug do
          "retained #{batch.records.size} records after retryable delivery failure " \
            "(#{result.error || result.status}); retry #{@retry_attempt} in #{delay.round(3)}s"
        end
        false
      end
      # From here backpressure samples out executions the app asked to keep,
      # and the receiver refusing them has no way to count them. Said once
      # per refusal, and refusal_ended says what it cost.
      if refusal
        defer_notification(
          DeliveryError.new("Railwatch ingest is refusing deliveries (#{refusal.reason}); holding " \
                            "#{batch.records.size} #{batch.records.size == 1 ? "record" : "records"}" \
                            "#{" and sampling down" if @config.backpressure} until it accepts again",
                            status: result.status)
        )
      end
      return unless gave_up

      # Losing a batch is not a debug-level event: with an ingest that never
      # comes back this is the only place the loss is ever reported, and the dropped counter it leaves behind
      # rides on the NEXT successful delivery, which may never happen.
      #
      # Reported here, after the lock is released, never inside it. The
      # callback is the app's: the documented one is Rails.error.report,
      # whose subscriber records the error as an exception and so writes
      # straight back into this reporter -- which needs @mutex to arm the
      # thread or ask for a flush, and under the lock that was
      # "ThreadError: deadlock; recursive locking" and a callback cut off
      # halfway. A slow callback under the lock was worse: shutdown's own
      # @mutex.synchronize and every request thread's write_now sat behind
      # it for as long as it took. notify_unsent and delivery_rejected
      # already call out unlocked; this was the one that did not.
      defer_notification(
        DeliveryError.new("Railwatch dropped #{batch.records.size} #{batch.records.size == 1 ? "record" : "records"} " \
                          "after #{MAX_RETRY_ATTEMPTS + 1} failed delivery attempts: " \
                          "#{result.error || result.status}",
                          status: result.status, records: batch.records.size, bytes: batch.bytes,
                          dropped: batch.dropped, dropped_bytes: batch.dropped_bytes)
      )
    end

    # The first delivery ingest accepted after refusing. The refusal was the
    # pressure, so the divisor goes straight back to one, as it went up,
    # rather than halving over three more flush ticks. A buffer still over
    # its high-water mark raises it again on the next tick, as it would have
    # anyway.
    def refusal_ended
      refusal, sampled_out, overflowed = @mutex.synchronize do
        ended = @refusal
        @refusal = nil
        [ ended, @sampled_out - ended.sampled_out, @buffer.overflowed - ended.overflowed ]
      end
      @backpressure_factor = 1.0
      dropped = overflowed + refusal.gave_up
      seconds = (Clock.monotonic - refusal.started_at).round
      defer_notification(
        DeliveryError.new("Railwatch ingest is accepting deliveries again after refusing for #{seconds}s; " \
                          "meanwhile backpressure sampled out #{sampled_out} " \
                          "#{sampled_out == 1 ? "execution" : "executions"} and #{dropped} " \
                          "#{dropped == 1 ? "record was" : "records were"} dropped",
                          records: dropped)
      )
    end

    # Never sooner than the ladder's rung either, so a receiver answering
    # "Retry-After: 0" gets backoff, not a loop.
    def refused_delay(retry_after_at)
      wanted = retry_after_at - Time.now
      return MAX_REFUSED_RETRY_DELAY * (0.5 + @random.rand * 0.5) if wanted > MAX_REFUSED_RETRY_DELAY

      [ wanted, retry_delay(@retry_attempt) ].max.clamp(0.0, MAX_REFUSED_RETRY_DELAY)
    end

    def failure_detail(result)
      [ result.status && "HTTP #{result.status}", result.error ].compact.reject { |part| part.to_s.empty? }.join(": ")
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
        @unreachable = false
      end
    end

    def delivery_rejected(batch, result)
      delivery_succeeded
      detail = result.error.to_s.empty? ? "HTTP #{result.status}" : result.error
      defer_notification(
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

    def deliver(batch)
      @transport.deliver(batch.records, dropped: batch.dropped, batch_id: batch.id,
                         dropped_bytes: batch.dropped_bytes, backpressure_factor: @backpressure_factor)
    end

    def update_backpressure
      unless @config.backpressure
        @backpressure_factor = 1.0
        return
      end

      buffered, _, buffered_bytes, = @buffer.stats
      high_water = @config.backpressure_high_water
      # A retry ladder is pressure when the receiver is struggling (a timeout,
      # a 5xx). Not when nothing listens (ECONNREFUSED): that is a server
      # restarting or a deploy handing over, back in a second or two, and
      # sampling down meanwhile only lost the app's first requests after it.
      # The buffer's high-water mark still bounds a receiver that stays away.
      retrying = @retry_attempt.positive? && !@unreachable
      pressured = buffered >= @config.buffer_size * high_water ||
        buffered_bytes >= @config.buffer_bytes * high_water || retrying
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
        DeliveryError.new("Railwatch #{reason} with #{records} unsent #{records == 1 ? "record" : "records"} " \
                          "retained in memory (#{bytes} bytes)",
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
