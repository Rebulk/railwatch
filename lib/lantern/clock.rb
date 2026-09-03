# frozen_string_literal: true

module Lantern
  # Wall time for timestamps, monotonic time for durations. Durations are
  # integers in microseconds everywhere, matching Nightwatch.
  module Clock
    module_function

    def now
      Process.clock_gettime(Process::CLOCK_REALTIME)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def micros_since(monotonic_start)
      ((monotonic - monotonic_start) * 1_000_000).round
    end

    def ms_to_micros(ms)
      (ms.to_f * 1_000).round
    end
  end
end
