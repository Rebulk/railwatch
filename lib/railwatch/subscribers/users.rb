# frozen_string_literal: true

module Railwatch
  module Subscribers
    # Resolves the current user. Default order: the app's Railwatch.user block,
    # then Current.user (authentication-zero, Rails 8 auth generator), then
    # Warden (Devise). Emits a `user` record once per user per process hour so
    # the platform can show names without every record carrying them.
    module Users
      extend Base

      module_function

      def install!(_app)
        subscribe("start_processing.action_controller") do |event|
          exe = execution or next
          exe.user_id = resolve_id(event.payload[:request]&.env)
        end
      end

      def resolve_id(env = nil)
        user = resolve_object(env) or return nil
        details = describe(user) or return nil
        remember(details)
        details[:id]
      rescue StandardError
        nil
      end

      def resolve_from_current
        resolve_id(nil)
      end

      # The beacon's resolution: the app's beacon_user block first, then the
      # same Current.user / Warden lookup a request gets.
      def resolve_beacon_id(request)
        if (resolver = Railwatch.config.beacon_user_resolver)
          user = resolver.call(request)
          if user
            details = describe(user) or return nil
            remember(details)
            return details[:id]
          end
        end
        resolve_id(request.env)
      rescue StandardError
        nil
      end

      def resolve_object(env)
        if defined?(::Current) && ::Current.respond_to?(:user) && ::Current.user
          ::Current.user
        elsif env && env["warden"].respond_to?(:user) && env["warden"].user
          env["warden"].user
        end
      end

      def describe(user)
        details = if (resolver = Railwatch.config.user_resolver)
          resolver.call(user)
        else
          {
            id: user.respond_to?(:id) ? user.id : user.to_s,
            name: user.respond_to?(:name) ? user.name : nil,
            email: user.respond_to?(:email) ? user.email : nil
          }
        end
        return nil unless details.is_a?(Hash) && details[:id]
        details = details.transform_values { |v| v&.to_s&.[](0, 255) }
        # Binding a known tenant onto the execution now (rather than leaving
        # it to Execution#envelope's lazy bind) is what makes the reference
        # below final, which is what lets `remember` trust its cache.
        if (tenant = Context.current_tenant)
          exe = execution
          exe.tenant = tenant if exe && exe.tenant.nil?
          details[:id] = Execution.qualified_user(details[:id], tenant)
        end
        details
      end

      # One `user` entity per id per process-hour. The cache entry is written
      # only once the entity has actually shipped, which is why the record is
      # parked on the execution (Execution#pending_users) and committed from
      # finish_execution instead of here: a first sighting inside a
      # sampled-out or paused execution writes no record, and must not
      # suppress the next sighting that would.
      #
      # @seen is a plain unsynchronized Hash, as it was before: in CRuby a
      # Hash store runs to completion under the GVL, so concurrent web
      # threads cannot corrupt it, and the worst a lost race costs is one
      # duplicate `user` record -- which the platform upserts by id.
      def remember(details)
        @seen ||= {}
        key = details[:id]
        now = Clock.now
        return if recently_seen?(key, now)

        exe = execution
        pending = exe&.pending_users
        return if pending&.key?(key)

        record = Railwatch.record(:user, id: key, name: details[:name], email: details[:email],
                                tenant: Context.current_tenant)
        return unless record

        exe ? (exe.pending_users ||= {})[key] = record : mark_seen(key, now)
        record
      end

      # Called from Railwatch.finish_execution, for a tree that is being handed
      # to the reporter, just before its records are written.
      def commit_execution!(exe)
        pending = exe.pending_users
        exe.pending_users = nil
        now = Clock.now
        pending.each do |key, record|
          # An over-full execution buffer drops the record it was handed, and
          # a failure-context ring can later shift it back out; either way the
          # entity never shipped. Identity, not `==`: two `user` records for
          # the same person are equal hashes.
          index = exe.records.index { |buffered| buffered.equal?(record) } or next

          # A tenant bound after the entity was resolved changes its
          # reference ("1" becomes "acme:1"), so this -- not the provisional
          # key `remember` checked -- is what the cache is keyed on. Such an
          # app therefore rebuilds the entity each request and discards the
          # duplicate here; that is one small hash, and the alternative
          # (trusting the provisional key) is what suppressed a second
          # tenant's user 1 entirely.
          reference = Execution.qualified_user(key, exe.tenant)
          if recently_seen?(reference, now)
            exe.records.delete_at(index)
          else
            record[:id] = reference
            record[:tenant] = exe.tenant if record[:tenant].nil?
            mark_seen(reference, now)
          end
        end
      end

      # A fork inherits this cache but not the reporter buffer the cached
      # entities were written to, so the child has to emit its own.
      def restart_after_fork!
        @seen = {}
        execution&.pending_users = nil
      end

      def recently_seen?(key, now)
        last = @seen[key]
        last && now - last < 3600
      end

      def mark_seen(key, now)
        @seen[key] = now
        @seen.delete(@seen.keys.first) if @seen.size > 10_000
      end
    end
  end
end
