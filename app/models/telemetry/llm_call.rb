# frozen_string_literal: true

module Telemetry
  class LlmCall < TelemetryRecord
    include Child

    # A tool invocation is a call in the same pipeline, so it shares this
    # table; it just has a name where a model call has a model.
    TOOL = "tool"

    scope :models, -> { where.not(operation: TOOL) }
    scope :tools, -> { where(operation: TOOL) }

    NANOS_PER_DOLLAR = 1_000_000_000.0

    # Dollars, or nil when the call is unpriced. Callers must render the
    # difference: an unpriced call is not a free one.
    def cost
      cost_nanos && cost_nanos / NANOS_PER_DOLLAR
    end

    # What the app paid for, which is the count a bill is drawn from.
    def total_tokens
      [input_tokens, output_tokens, cache_read_tokens, cache_write_tokens].compact.sum
    end

    def timeline_label
      tool? ? tool_name.to_s : "#{provider}/#{model}"
    end

    def tool?
      operation == TOOL
    end
  end
end
