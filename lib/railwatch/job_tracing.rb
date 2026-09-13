# frozen_string_literal: true

module Railwatch
  # Carries trace_id, the enqueuing execution id, and that execution's user
  # and tenant inside the Active Job payload, the same way Rails carries
  # locale and timezone, so a job attempt links back to the request that
  # enqueued it and is attributed to the same person and tenant.
  module JobTracing
    extend ActiveSupport::Concern

    included do
      attr_accessor :railwatch_trace_id, :railwatch_parent_id, :railwatch_user, :railwatch_tenant
    end

    def serialize
      exe = Railwatch.execution
      data = super.merge(
        "railwatch_trace_id" => railwatch_trace_id || exe&.trace_id,
        "railwatch_parent_id" => railwatch_parent_id || exe&.id
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
      # nothing to attribute (and Railwatch disabled), so nothing is resolved.
      user = railwatch_user || (exe && (exe.user_id ||= Subscribers::Users.resolve_from_current))
      tenant = railwatch_tenant || exe&.tenant || Context.current_tenant
      data["railwatch_user"] = user if user
      data["railwatch_tenant"] = tenant if tenant
      data
    end

    def deserialize(job_data)
      super
      self.railwatch_trace_id = job_data["railwatch_trace_id"]
      self.railwatch_parent_id = job_data["railwatch_parent_id"]
      self.railwatch_user = job_data["railwatch_user"]
      self.railwatch_tenant = job_data["railwatch_tenant"]
    end
  end
end
