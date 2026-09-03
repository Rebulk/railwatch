# frozen_string_literal: true

module Lantern
  # Carries trace_id and the enqueuing execution id inside the Active Job
  # payload, the same way Rails carries locale and timezone, so a job attempt
  # links back to the request that enqueued it.
  module JobTracing
    extend ActiveSupport::Concern

    included do
      attr_accessor :lantern_trace_id, :lantern_parent_id
    end

    def serialize
      exe = Lantern.execution
      super.merge(
        "lantern_trace_id" => lantern_trace_id || exe&.trace_id,
        "lantern_parent_id" => lantern_parent_id || exe&.id
      )
    end

    def deserialize(job_data)
      super
      self.lantern_trace_id = job_data["lantern_trace_id"]
      self.lantern_parent_id = job_data["lantern_parent_id"]
    end
  end
end
