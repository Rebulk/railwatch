# frozen_string_literal: true

module Lantern
  # Bounded, thread-safe queue of records. When full, the oldest record is
  # dropped and counted; the drop count is reported with the next batch so
  # loss is visible on the platform instead of silent.
  class Buffer
    def initialize(capacity)
      @capacity = capacity
      @records = []
      @dropped = 0
      @mutex = Mutex.new
    end

    def push(record)
      @mutex.synchronize do
        if @records.size >= @capacity
          @records.shift
          @dropped += 1
        end
        @records << record
        @records.size
      end
    end

    def size
      @mutex.synchronize { @records.size }
    end

    def dropped
      @mutex.synchronize { @dropped }
    end

    def stats
      @mutex.synchronize { [ @records.size, @dropped ] }
    end

    def account_dropped(count)
      @mutex.synchronize { @dropped += count }
    end

    def full?(threshold)
      size >= threshold
    end

    # Atomically take everything, resetting the drop counter.
    def drain
      @mutex.synchronize do
        batch = @records
        dropped = @dropped
        @records = []
        @dropped = 0
        [ batch, dropped ]
      end
    end

    # Put an unsuccessfully delivered batch back ahead of records written
    # while it was in flight. The queue stays bounded: if both generations no
    # longer fit, the oldest restored records are discarded first so fresh
    # application telemetry wins under sustained ingest failure.
    def restore(records, dropped: 0)
      @mutex.synchronize do
        @records = records + @records
        overflow = [ @records.size - @capacity, 0 ].max
        @records.shift(overflow)
        @dropped += dropped + overflow
        @records.size
      end
    end
  end
end
