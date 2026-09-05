# frozen_string_literal: true

module Lantern
  # Header and parameter redaction. Parameter redaction reuses the app's own
  # Rails.application.config.filter_parameters plus Lantern's list, so
  # anything the app already hides from logs is hidden here too.
  class Redactor
    FILTERED = "[FILTERED]"
    # Credentials are often carried in vendor-specific headers that an app
    # cannot enumerate ahead of time (X-Api-Key, Stripe-Signature,
    # X-Auth-Token, and similar). Match credential-shaped name segments in
    # addition to the exact configurable denylist.
    SENSITIVE_HEADER_NAME = %r{
      (?:\A|-)
      (?:
        api-?key|access-?key|private-?key|
        auth(?:entication|orization)?|bearer|credential|
        hmac|jwt|token|secret|signature
      )
      (?:-|\z)
    }ix

    def initialize(config)
      @config = config
      @header_keys = config.redact_headers.map { |h| h.downcase }.to_set
      @param_filter = nil
    end

    def headers(hash)
      hash.each_with_object({}) do |(k, v), out|
        out[k] = redact_header?(k) ? FILTERED : v.to_s[0, 512]
      end
    end

    # Header names arrive already capitalised ("Authorization"); the lookup
    # set is lower-case, so cache the downcased form per distinct name.
    def redact_header?(name)
      @header_case ||= {}
      hit = @header_case[name]
      return hit unless hit.nil?
      @header_case.clear if @header_case.size > 512
      normalized = name.to_s.downcase
      @header_case[name] = @header_keys.include?(normalized) || SENSITIVE_HEADER_NAME.match?(normalized)
    end

    def params(hash)
      param_filter.filter(hash)
    rescue StandardError
      {}
    end

    private

    def param_filter
      @param_filter ||= begin
        filters = @config.redact_params.dup
        filters.concat(Rails.application.config.filter_parameters) if defined?(Rails) && Rails.application
        ActiveSupport::ParameterFilter.new(filters.uniq, mask: FILTERED)
      end
    end
  end
end
