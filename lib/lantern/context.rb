# frozen_string_literal: true

module Lantern
  # Bridges Rails' three context stores. Anything an app already sets on
  # ActiveSupport::ExecutionContext, Rails.error, or Rails.event shows up on
  # Lantern records; Lantern.context writes to all three.
  module Context
    LIMIT = 65_536
    EMPTY_JSON = "{}".freeze
    # Present, and true, on a context that did not fit in LIMIT bytes.
    TRUNCATION_KEY = "_lantern_truncated"
    TRUNCATION_MARKER = "[TRUNCATED]"

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

      serialize(ctx)
    rescue StandardError
      EMPTY_JSON
    end

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
