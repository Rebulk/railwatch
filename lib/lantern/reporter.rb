# frozen_string_literal: true

module Lantern
  # One background thread per process. Drains the buffer every flush_interval
  # seconds or when the buffer crosses flush_threshold, and posts to the
  # platform. Re-armed after fork so Puma cluster workers and Solid Queue
  # forked workers each get their own thread. Nothing here touches the app
  # database.
  class Reporter
    attr_reader :buffer

    def initialize(config, transport: nil)
      @config = config
      @buffer = Buffer.new(config.buffer_size)
      @transport = transport || Transport::Http.new(config)
      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @pid = nil
      @stopping = false
    end

    def write(record)
      size = @buffer.push(record)
      ensure_thread
      signal if size >= @config.flush_threshold
    end

    # Bypass the batch and send right away. Used for unhandled exceptions so a
    # crashing process still reports.
    def write_now(record)
      @buffer.push(record)
      flush
    end

    def flush
      batch, dropped = @buffer.drain
      return if batch.empty?

      batch = Lantern.run_before_ingest(batch)
      return if batch.empty?

      result = @transport.deliver(batch, dropped: dropped)
      Lantern.debug { "flushed #{batch.size} records (dropped #{dropped}): #{result.to_h}" }
      result
    end

    def ensure_thread
      return if @thread&.alive? && @pid == Process.pid

      @mutex.synchronize do
        return if @thread&.alive? && @pid == Process.pid

        @pid = Process.pid
        @stopping = false
        @thread = Thread.new { run }
        @thread.name = "lantern-reporter"
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    def shutdown
      @stopping = true
      signal
      @thread&.join(@config.shutdown_timeout)
      flush
    rescue StandardError => e
      Lantern.debug { "shutdown flush failed: #{e.class}: #{e.message}" }
    end

    private

    def signal
      @mutex.synchronize { @wakeup.signal }
    end

    def run
      until @stopping
        @mutex.synchronize { @wakeup.wait(@mutex, @config.flush_interval) }
        begin
          flush
        rescue StandardError => e
          Lantern.debug { "flush error: #{e.class}: #{e.message}" }
        end
      end
    end
  end
end
