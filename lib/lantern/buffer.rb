# frozen_string_literal: true

module Lantern
  # Bounded, thread-safe queue of records. When full, the oldest record is
  # dropped and counted; the drop count is reported with the next batch so
  # loss is visible on the platform instead of silent.
  class Buffer
    attr_reader :dropped

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
  end
end
