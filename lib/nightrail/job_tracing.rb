# frozen_string_literal: true

module Nightrail
  # Carries trace_id, the enqueuing execution id, and that execution's user
  # and tenant inside the Active Job payload, the same way Rails carries
  # locale and timezone, so a job attempt links back to the request that
  # enqueued it and is attributed to the same person and tenant.
  module JobTracing
    extend ActiveSupport::Concern

    included do
      attr_accessor :nightrail_trace_id, :nightrail_parent_id, :nightrail_user, :nightrail_tenant
    end

    def serialize
      exe = Nightrail.execution
      data = super.merge(
        "nightrail_trace_id" => nightrail_trace_id || exe&.trace_id,
        "nightrail_parent_id" => nightrail_parent_id || exe&.id
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
      # nothing to attribute (and Nightrail disabled), so nothing is resolved.
      user = nightrail_user || (exe && (exe.user_id ||= Subscribers::Users.resolve_from_current))
      tenant = nightrail_tenant || exe&.tenant || Context.current_tenant
      data["nightrail_user"] = user if user
      data["nightrail_tenant"] = tenant if tenant
      data
    end

    def deserialize(job_data)
      super
      self.nightrail_trace_id = job_data["nightrail_trace_id"]
      self.nightrail_parent_id = job_data["nightrail_parent_id"]
      self.nightrail_user = job_data["nightrail_user"]
      self.nightrail_tenant = job_data["nightrail_tenant"]
    end
  end
end
