# frozen_string_literal: true

module Lantern
  # Bridges Rails' three context stores. Anything an app already sets on
  # ActiveSupport::ExecutionContext, Rails.error, or Rails.event shows up on
  # Lantern records; Lantern.context writes to all three.
  module Context
    LIMIT = 65_536
    EMPTY_JSON = "{}".freeze

    module_function

    def set(**attrs)
      ActiveSupport::ExecutionContext.set(**attrs)
      Rails.error.set_context(**attrs) if defined?(Rails) && Rails.respond_to?(:error)
      Rails.event.set_context(**attrs) if defined?(Rails) && Rails.respond_to?(:event)
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
      json = JSON.generate(ctx)
      json.bytesize > LIMIT ? json.byteslice(0, LIMIT) : json
    rescue StandardError
      "{}"
    end

    def current_tenant
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
      json = JSON.generate(current.merge(extra || {}))
      json.bytesize > LIMIT ? json.byteslice(0, LIMIT) : json
    rescue StandardError
      "{}"
    end
  end
end
