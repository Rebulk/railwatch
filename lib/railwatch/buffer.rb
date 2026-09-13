# frozen_string_literal: true

module Railwatch
  # Bounded, thread-safe queue of records. When full, the oldest record is
  # dropped and counted; the drop count is reported with the next batch so
  # loss is visible on the platform instead of silent.
  #
  # "Full" is two limits, not one. A record count alone does not bound memory:
  # 10,000 records is a few megabytes of ordinary telemetry and a gigabyte of
  # captured attachments or a query record carrying a multi-megabyte SQL
  # string. Each record's weight is measured once, when it is pushed, and
  # carried alongside it so shifting one out is arithmetic rather than a
  # re-measure.
  class Buffer
    def initialize(capacity, byte_capacity: Float::INFINITY)
      @capacity = capacity
      @byte_capacity = byte_capacity
      @records = []
      @record_bytes = []
      @bytes = 0
      @dropped = 0
      @dropped_bytes = 0
      @mutex = Mutex.new
    end

    # `bytes` is the caller's already-measured weight (Execution weighed the
    # record when it buffered it); anything else is weighed here. Weighing
    # stops at the ceiling, so the dropped-byte counter is a floor for an
    # over-ceiling record; the dropped-record counter is always exact.
    def push(record, bytes = nil)
      bytes ||= Record.buffered_bytes(record, limit: @byte_capacity)
      @mutex.synchronize do
        # A single record heavier than the whole queue can only be dropped:
        # making room for it would mean emptying the queue and still not
        # fitting.
        if bytes > @byte_capacity
          drop(bytes)
          next @records.size
        end

        drop_oldest while @records.any? && (@records.size >= @capacity || @bytes + bytes > @byte_capacity)
        @records << record
        @record_bytes << bytes
        @bytes += bytes
        @records.size
      end
    end

    def size
      @mutex.synchronize { @records.size }
    end

    def dropped
      @mutex.synchronize { @dropped }
    end

    def bytes
      @mutex.synchronize { @bytes }
    end

    def stats
      @mutex.synchronize { [ @records.size, @dropped, @bytes, @dropped_bytes ] }
    end

    def account_dropped(count, bytes: 0)
      @mutex.synchronize do
        @dropped += count
        @dropped_bytes += bytes
      end
    end

    def full?(threshold)
      size >= threshold
    end

    # Atomically take everything, resetting the drop counters. Returns the
    # records with the weights measured when they were pushed, so the reporter
    # can split a batch by bytes without weighing anything twice.
    def drain
      @mutex.synchronize do
        drained = [ @records, @dropped, @dropped_bytes, @record_bytes ]
        @records = []
        @record_bytes = []
        @bytes = 0
        @dropped = 0
        @dropped_bytes = 0
        drained
      end
    end

    # Put an unsuccessfully delivered batch back ahead of records written
    # while it was in flight. The queue stays bounded: if both generations no
    # longer fit, the oldest restored records are discarded first so fresh
    # application telemetry wins under sustained ingest failure.
    def restore(records, sizes = nil, dropped: 0, dropped_bytes: 0)
      sizes ||= records.map { |record| Record.buffered_bytes(record, limit: @byte_capacity) }
      @mutex.synchronize do
        @records = records + @records
        @record_bytes = sizes + @record_bytes
        @bytes += sizes.sum
        @dropped += dropped
        @dropped_bytes += dropped_bytes
        drop_oldest while @records.any? && (@records.size > @capacity || @bytes > @byte_capacity)
        @records.size
      end
    end

    private

    def drop(bytes)
      @dropped += 1
      @dropped_bytes += bytes
    end

    def drop_oldest
      @records.shift
      bytes = @record_bytes.shift
      @bytes -= bytes
      drop(bytes)
    end
  end
end
