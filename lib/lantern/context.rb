# frozen_string_literal: true

module Lantern
  # Bridges Rails' three context stores. Anything an app already sets on
  # ActiveSupport::ExecutionContext, Rails.error, or Rails.event shows up on
  # Lantern records; Lantern.context writes to all three.
  module Context
    LIMIT = 65_536
    EMPTY_JSON = "{}".freeze
    OVERRIDE_KEY = :lantern_context_snapshot

    Snapshot = Struct.new(:values, :tenant, :write_through, keyword_init: true)

    module_function

    def set(**attrs)
      if (snapshot = override)
        # A response body can be consumed on a thread that already belongs to
        # unrelated Rails work. Keep Lantern.context changes in the captured
        # request snapshot. Only mirror them into Rails' stores when this is
        # the originating context; never contaminate another thread or fiber.
        snapshot.values.merge!(attrs)
        return attrs unless snapshot.write_through
      end

      ActiveSupport::ExecutionContext.set(**attrs)
      Rails.error.set_context(**attrs) if defined?(Rails) && Rails.respond_to?(:error)
      Rails.event.set_context(**attrs) if defined?(Rails) && Rails.respond_to?(:event)
      attrs
    end

    def current
      return override.values.dup if override

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
      json = JSON.generate(ctx)
      json.bytesize > LIMIT ? json.byteslice(0, LIMIT) : json
    rescue StandardError
      "{}"
    end

    def snapshot
      Snapshot.new(values: current, tenant: current_tenant)
    end

    def with(snapshot)
      state = ActiveSupport::IsolatedExecutionState
      had_previous = state.key?(OVERRIDE_KEY)
      previous = state[OVERRIDE_KEY] if had_previous
      state[OVERRIDE_KEY] = snapshot
      yield snapshot
    ensure
      if had_previous
        state[OVERRIDE_KEY] = previous
      else
        state.delete(OVERRIDE_KEY)
      end
    end

    def current_tenant
      return override.tenant if override

      if defined?(::TenantRecord) && ::TenantRecord.respond_to?(:current_tenant)
        ::TenantRecord.current_tenant&.to_s
      elsif defined?(::ActiveRecord::Tenanted) && ::ActiveRecord::Base.respond_to?(:current_tenant)
        ::ActiveRecord::Base.current_tenant&.to_s
      end
    rescue StandardError
      nil
    end

    def override
      ActiveSupport::IsolatedExecutionState[OVERRIDE_KEY]
    end
  end
end

module Lantern
  module Context
    def self.serialized_with(extra)
      json = JSON.generate(current.merge(extra || {}))
      json.bytesize > LIMIT ? json.byteslice(0, LIMIT) : json
    rescue StandardError
      "{}"
    end
  end
end
