# frozen_string_literal: true

module Railwatch
  # Parses and applies the "key:value key2:value2 free text" grammar shared by
  # telemetry pages, REST endpoints, and MCP tools.
  module FilterQuery
    TOKEN = /\A([a-z_]+):(\S+)\z/
    EXECUTION_KINDS = %w[request job scheduled_task command].freeze
    LOG_LEVELS = %w[debug info warn error fatal event unknown].freeze
    HANDLED_VALUES = %w[true false].freeze

    COMMON_FIELDS = %w[after before user tenant deploy kind].freeze
    RESOURCE_FIELDS = {
      jobs: %w[class job_id outcome queue status],
      exceptions: %w[source class handled severity status],
      logs: %w[source level status],
      queries: %w[source adapter connection role]
    }.freeze

    def self.parse(query)
      text = []
      fields = {}
      query.to_s.split(/\s+/).each do |word|
        if (m = TOKEN.match(word))
          fields[m[1]] = m[2]
        elsif word.present?
          text << word
        end
      end
      { text: text.join(" "), fields: fields }
    end

    # "5xx" -> 500..599, "404" -> 404..404, anything else -> nil
    def self.status_range(value)
      case value.to_s
      when /\A([2-5])xx\z/i then ($1.to_i * 100)..($1.to_i * 100 + 99)
      when /\A\d+\z/ then value.to_i..value.to_i
      end
    end

    def self.fields_for(resource)
      COMMON_FIELDS + RESOURCE_FIELDS.fetch(resource.to_sym)
    end

    def self.cursor_context(environment_id:, resource:, query:, window:)
      Digest::SHA256.hexdigest([ environment_id, resource, query.to_s, window ].to_json)
    end

    # Applies the same telemetry grammar for the web UI, REST API, and MCP.
    # The supplied window remains the outer bound; after:/before: may only
    # narrow it. Unknown fields are inert, and every value is bound through
    # Active Record rather than interpolated into SQL.
    def self.apply(scope, resource:, query:, from:, to:, except: [])
      resource = resource.to_sym
      parsed = parse(query)
      fields = parsed[:fields].except(*Array(except).map(&:to_s))
      scope = scope.where(occurred_at: bounded_time_range(fields, from, to))
      scope = apply_common(scope, fields)

      case resource
      when :jobs then apply_jobs(scope, fields, parsed[:text])
      when :exceptions then apply_exceptions(scope, fields, parsed[:text])
      when :logs then apply_logs(scope, fields, parsed[:text])
      when :queries then apply_queries(scope, fields, parsed[:text])
      else raise ArgumentError, "unsupported telemetry resource: #{resource}"
      end
    end

    def self.bounded_time_range(fields, from, to)
      after = parse_time(fields["after"])
      before = parse_time(fields["before"])
      lower = [ from, after ].compact.max
      upper = [ to, before ].compact.min
      lower <= upper ? lower..upper : (lower...lower)
    end
    private_class_method :bounded_time_range

    def self.parse_time(value)
      return if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :parse_time

    def self.apply_common(scope, fields)
      scope = scope.where(user_ref: fields["user"]) if fields["user"].present?
      scope = scope.where(app_tenant: fields["tenant"]) if fields["tenant"].present?
      scope = scope.where(deploy: fields["deploy"]) if fields["deploy"].present?
      if fields["source"].present?
        if EXECUTION_KINDS.include?(fields["source"].to_s) && scope.klass.column_names.include?("execution_source")
          scope = scope.where(execution_source: fields["source"])
        elsif scope.klass.column_names.include?("source")
          pattern = "#{scope.klass.sanitize_sql_like(fields["source"])}%"
          scope = scope.where(scope.klass.arel_table[:source].matches(pattern))
        end
      end
      scope = scope.where(execution_source: fields["kind"]) if EXECUTION_KINDS.include?(fields["kind"].to_s) && scope.klass.column_names.include?("execution_source")
      scope
    end
    private_class_method :apply_common

    def self.apply_jobs(scope, fields, text)
      outcome = fields["outcome"].presence || fields["status"].presence
      scope = scope.where(queue: fields["queue"]) if fields["queue"].present?
      scope = scope.where(outcome: outcome) if outcome
      scope = scope.where(name: fields["class"]) if fields["class"].present?
      scope = scope.where(job_id: fields["job_id"]) if fields["job_id"].present?
      return scope unless text.present?
      pattern = "%#{Telemetry::Execution.sanitize_sql_like(text)}%"
      scope.where("name LIKE :pattern OR exception_preview LIKE :pattern", pattern: pattern)
    end
    private_class_method :apply_jobs

    def self.apply_exceptions(scope, fields, text)
      handled = fields["handled"]
      handled ||= { "handled" => "true", "unhandled" => "false" }[fields["status"]]
      scope = scope.where(class_name: fields["class"]) if fields["class"].present?
      scope = scope.where(handled: handled == "true") if HANDLED_VALUES.include?(handled.to_s)
      scope = scope.where(severity: fields["severity"]) if fields["severity"].present?
      return scope unless text.present?
      pattern = "%#{Telemetry::Exception.sanitize_sql_like(text)}%"
      scope.where("message LIKE :pattern OR class_name LIKE :pattern", pattern: pattern)
    end
    private_class_method :apply_exceptions

    def self.apply_logs(scope, fields, text)
      level = fields["level"].presence || fields["status"].presence
      scope = scope.where(level: level) if LOG_LEVELS.include?(level.to_s)
      text.present? ? scope.fts(text) : scope
    end
    private_class_method :apply_logs

    def self.apply_queries(scope, fields, text)
      %w[adapter connection role].each do |field|
        scope = scope.where(field => fields[field]) if fields[field].present?
      end
      return scope unless text.present?
      scope.matching(text)
    end
    private_class_method :apply_queries
  end
end
