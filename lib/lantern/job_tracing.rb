# frozen_string_literal: true

module Lantern
  # Carries trace_id, the enqueuing execution id, and that execution's user
  # and tenant inside the Active Job payload, the same way Rails carries
  # locale and timezone, so a job attempt links back to the request that
  # enqueued it and is attributed to the same person and tenant.
  module JobTracing
    extend ActiveSupport::Concern

    included do
      attr_accessor :lantern_trace_id, :lantern_parent_id, :lantern_user, :lantern_tenant,
                    :lantern_task_key, :lantern_schedule, :lantern_scheduled_at
    end

    def serialize
      exe = Lantern.execution
      data = super.merge(
        "lantern_trace_id" => lantern_trace_id || exe&.trace_id,
        "lantern_parent_id" => lantern_parent_id || exe&.id
      )
      # Identifier strings only -- never a user or tenant record -- and only
      # when there is one, so a job enqueued with no identity produces the
      # same payload it did before these keys existed.
      #
      # A request resolves its user lazily, at the end (Middleware::Request),
      # so exe.user_id is usually still nil while the action is enqueuing;
      # resolving here is what gives such a job its user. The result is
      # memoised onto the execution with the same `||=` the middleware uses,
      # so an action that enqueues fifty jobs resolves once, not fifty
      # times -- resolving a present user costs ~8us. Inside a job the
      # restored value is already on the execution and wins, so identity
      # flows on unchanged through jobs that enqueue jobs. No execution means
      # nothing to attribute (and Lantern disabled), so nothing is resolved.
      user = lantern_user || (exe && (exe.user_id ||= Subscribers::Users.resolve_from_current))
      tenant = lantern_tenant || exe&.tenant || Context.current_tenant
      data["lantern_user"] = user.to_s if user
      data["lantern_tenant"] = tenant.to_s if tenant
      schedule = Lantern::JobAdapters.current_schedule
      data["lantern_task_key"] = (lantern_task_key || schedule&.dig(:task_key)).to_s if lantern_task_key || schedule
      data["lantern_schedule"] = (lantern_schedule || schedule&.dig(:schedule))&.to_s if lantern_schedule || schedule
      scheduled_at = lantern_scheduled_at || schedule&.dig(:run_at)
      data["lantern_scheduled_at"] = scheduled_at.to_f if scheduled_at
      data
    end

    def deserialize(job_data)
      super
      self.lantern_trace_id = job_data["lantern_trace_id"]
      self.lantern_parent_id = job_data["lantern_parent_id"]
      self.lantern_user = job_data["lantern_user"]
      self.lantern_tenant = job_data["lantern_tenant"]
      self.lantern_task_key = job_data["lantern_task_key"]
      self.lantern_schedule = job_data["lantern_schedule"]
      self.lantern_scheduled_at = job_data["lantern_scheduled_at"]
    end
  end
end
