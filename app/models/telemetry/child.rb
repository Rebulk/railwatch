# frozen_string_literal: true

module Telemetry
  # Shared behaviour for every record that belongs to an execution.
  module Child
    extend ActiveSupport::Concern

    included do
      scope :recent, -> { order(occurred_at: :desc) }
      scope :between, ->(from, to) { where(occurred_at: from..to) }
      scope :in_execution, ->(id) { where(execution_id: id) }
    end

    class_methods do
      # One execution's rows for the waterfall; a child that resolves a
      # column from elsewhere (Query) overrides this.
      def timeline_scope(execution_id)
        in_execution(execution_id)
      end
    end

    def execution
      Execution.find_by(execution_id: execution_id)
    end

    def duration_ms
      respond_to?(:duration) && duration ? duration / 1000.0 : nil
    end

    def timeline_entry(type)
      parent_start = execution&.occurred_at
      {
        type: type.to_s.singularize,
        id: id,
        offset: parent_start ? ((occurred_at - parent_start) * 1000.0).round(3) : 0,
        duration: duration_ms,
        label: timeline_label,
        stage: execution_stage,
        source: (self[:source] if has_attribute?(:source))
      }
    end

    def timeline_label
      try(:name) || try(:key) || try(:message)&.first(120) || self.class.name.demodulize
    end
  end
end
