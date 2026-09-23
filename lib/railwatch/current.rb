# frozen_string_literal: true

module Railwatch
  # Thread- or fiber-local pointer to the running Execution. Uses the same
  # isolation level as Rails (config.active_support.isolation_level) so Solid
  # Queue fiber workers and Puma threads both work.
  module Current
    KEY = :railwatch_execution
    INTERNAL_KEY = :railwatch_internal

    module_function

    def execution
      ActiveSupport::IsolatedExecutionState[KEY]
    end

    def execution=(value)
      ActiveSupport::IsolatedExecutionState[KEY] = value
    end

    def with(execution)
      previous = self.execution
      self.execution = execution
      yield execution
    ensure
      self.execution = previous
    end

    def clear
      ActiveSupport::IsolatedExecutionState.delete(KEY)
    end

    # True while this thread (or fiber) is doing Railwatch's own work: see
    # Railwatch.internal. A depth, not a boolean, so nesting unwinds cleanly.
    def internal?
      ActiveSupport::IsolatedExecutionState[INTERNAL_KEY].to_i.positive?
    end

    def internal
      depth = ActiveSupport::IsolatedExecutionState[INTERNAL_KEY].to_i
      ActiveSupport::IsolatedExecutionState[INTERNAL_KEY] = depth + 1
      yield
    ensure
      if depth.zero?
        ActiveSupport::IsolatedExecutionState.delete(INTERNAL_KEY)
      else
        ActiveSupport::IsolatedExecutionState[INTERNAL_KEY] = depth
      end
    end
  end
end
