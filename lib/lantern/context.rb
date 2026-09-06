# frozen_string_literal: true

module Lantern
  # Bridges Rails' three context stores. Anything an app already sets on
  # ActiveSupport::ExecutionContext, Rails.error, or Rails.event shows up on
  # Lantern records; Lantern.context writes to all three.
  module Context
    LIMIT = 65_536
    EMPTY_JSON = "{}".freeze
    EXECUTION_CONTEXT_KEY = :active_support_execution_context
    # Present, and true, on a context that did not fit in LIMIT bytes.
    TRUNCATION_KEY = "_lantern_truncated"
    TRUNCATION_MARKER = "[TRUNCATED]"

    module_function

    def set(**attrs)
      ActiveSupport::ExecutionContext.set(**attrs)
      Rails.error.set_context(**attrs) if defined?(Rails) && Rails.respond_to?(:error)
      Rails.event.set_context(**attrs) if defined?(Rails) && Rails.respond_to?(:event)
      # An explicit tenant is bound to the running execution here rather than
      # read back out of ActiveSupport::ExecutionContext on demand: reading it
      # there means ExecutionContext.to_h, which dups the whole store, and
      # current_tenant is called once per record from Execution#envelope.
      # Binding it also requalifies the records already buffered for this
      # execution (Execution#tenant=).
      tenant = attrs[:tenant]
      Current.execution&.tenant = tenant.to_s if tenant
      attrs
    end

    def current
      ctx = {}
      ctx.merge!(ActiveSupport::ExecutionContext.to_h.except(:controller, :job))
      ctx.merge!(Rails.event.context) if defined?(Rails) && Rails.respond_to?(:event) && Rails.event.respond_to?(:context)
      ctx
    rescue StandardError
      {}
    end

    def serialized
      ctx = current
      return EMPTY_JSON if ctx.empty?

      serialize(ctx)
    rescue StandardError
      EMPTY_JSON
    end

    # Run deferred Rack body work under a bounded, already-redacted copy of
    # the originating request context. Rack servers may consume a body on a
    # different thread/fiber, or reuse the original carrier for unrelated
    # work after Rails has cleared its logical execution context. Swapping the
    # complete ExecutionContext record keeps that consumer's CurrentAttributes
    # and private ambient context out of Lantern records, then restores it
    # exactly when consumption ends.
    def with_serialized(serialized)
      attributes = JSON.parse(serialized, symbolize_names: true)
      attributes = {} unless attributes.is_a?(Hash)
      state = ActiveSupport::IsolatedExecutionState
      previous_record = state[EXECUTION_CONTEXT_KEY]
      event = Rails.event if defined?(Rails) && Rails.respond_to?(:event)
      previous_event_context = event.context if event&.respond_to?(:context)

      state.delete(EXECUTION_CONTEXT_KEY)
      event.clear_context if event&.respond_to?(:clear_context)
      ActiveSupport::ExecutionContext.set(**attributes)
      event.set_context(attributes) if event&.respond_to?(:set_context)
      yield
    ensure
      restore_safely do
        if previous_record
          state[EXECUTION_CONTEXT_KEY] = previous_record
        else
          state&.delete(EXECUTION_CONTEXT_KEY)
        end
      end
      # ExecutionContext callbacks (for example tagged logging) need to see
      # the restored record even though the record itself is restored whole.
      restore_safely { ActiveSupport::ExecutionContext.set if state }
      restore_safely do
        if event&.respond_to?(:clear_context)
          event.clear_context
          event.set_context(previous_event_context) if previous_event_context&.any?
        end
      end
    end

    # A failing application callback during cleanup must not replace a body
    # exception or prevent the remaining consumer context from being restored.
    def restore_safely
      yield
    rescue StandardError => e
      Lantern.debug { "streaming context restoration failed: #{e.class}: #{e.message}" }
    end
    private_class_method :restore_safely

    # Context is application data -- an app that puts an API token or a
    # password in it should get the same treatment request params get, rather
    # than having it written verbatim onto every record built while it is set.
    def serialize(context)
      filtered = Lantern.redactor.params(context)
      json = JSON.generate(filtered)
      json.bytesize > LIMIT ? truncate(filtered) : json
    end

    # An oversized context used to be byteslice'd, which cut the JSON
    # mid-string or mid-object: the platform could not parse it, so the whole
    # context was lost rather than most of it. Rebuild a smaller context
    # instead. Whole values are kept while they fit, an oversized String is
    # cut and marked, anything that still does not fit is dropped, and
    # `_lantern_truncated` says it happened. The result is always valid JSON.
    def truncate(filtered)
      out = { TRUNCATION_KEY => true }
      budget = LIMIT - JSON.generate(out).bytesize
      filtered.each do |key, value|
        next if key.to_s == TRUNCATION_KEY

        cost = pair_bytes(key, value)
        if cost > budget && value.is_a?(String)
          value = truncated_string(value, budget - (cost - JSON.generate(value).bytesize)) or next
          cost = pair_bytes(key, value)
        end
        next if cost > budget

        budget -= cost
        out[key] = value
      end
      JSON.generate(out)
    end

    # What this pair costs inside a larger object: the encoded `{"k":v}` less
    # its two braces, plus the comma that separates it from the pair before.
    def pair_bytes(key, value)
      JSON.generate(key.to_s => value).bytesize - 1
    end

    # `room` is a floor rather than a fit: JSON escaping can expand one
    # character into six bytes, so the caller re-measures the pair and drops
    # it if the escaped result is still too large.
    def truncated_string(value, room)
      keep = room - TRUNCATION_MARKER.bytesize - 2
      return nil if keep <= 0

      "#{value.byteslice(0, keep).to_s.scrub("")}#{TRUNCATION_MARKER}"
    end

    def current_tenant
      exe = Current.execution
      return exe.tenant if exe&.tenant

      if defined?(::TenantRecord) && ::TenantRecord.respond_to?(:current_tenant)
        ::TenantRecord.current_tenant&.to_s
      elsif defined?(::ActiveRecord::Tenanted) && ::ActiveRecord::Base.respond_to?(:current_tenant)
        ::ActiveRecord::Base.current_tenant&.to_s
      end
    rescue StandardError
      nil
    end
  end
end

module Lantern
  module Context
    def self.serialized_with(extra)
      ctx = current.merge(extra || {})
      return EMPTY_JSON if ctx.empty?

      serialize(ctx)
    rescue StandardError
      EMPTY_JSON
    end
  end
end
