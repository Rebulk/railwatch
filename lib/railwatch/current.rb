# frozen_string_literal: true

module Railwatch
  # Thread- or fiber-local pointer to the running Execution. Uses the same
  # isolation level as Rails (config.active_support.isolation_level) so Solid
  # Queue fiber workers and Puma threads both work.
  module Current
    KEY = :railwatch_execution

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
  end
end
