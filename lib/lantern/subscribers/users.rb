# frozen_string_literal: true

module Lantern
  module Subscribers
    # Resolves the current user. Default order: the app's Lantern.user block,
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
        if (resolver = Lantern.config.beacon_user_resolver)
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
        details = if (resolver = Lantern.config.user_resolver)
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
        details[:id] = [ Context.current_tenant, details[:id] ].compact.join(":") if Context.current_tenant
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
        seen = (@seen ||= {})
        key = details[:id]
        now = Clock.now
        last = seen[key]
        return if last && now - last < 3600

        exe = execution
        pending = exe&.pending_users
        return if pending&.key?(key)

        record = Lantern.record(:user, id: key, name: details[:name], email: details[:email],
                                tenant: Context.current_tenant)
        return unless record

        exe ? (exe.pending_users ||= {})[key] = record : mark_seen(key, now)
        record
      end

      # Called from Lantern.finish_execution for a tree that is being handed
      # to the reporter.
      def commit_execution!(exe)
        pending = exe.pending_users
        exe.pending_users = nil
        now = Clock.now
        pending.each { |key, record| mark_seen(key, now) if buffered?(exe, record) }
      end

      # A fork inherits this cache but not the reporter buffer the cached
      # entities were written to, so the child has to emit its own.
      def restart_after_fork!
        @seen = {}
        execution&.pending_users = nil
      end

      # An over-full execution buffer drops the record it was handed, and a
      # failure-context ring can later shift it back out; either way the
      # entity never shipped. Identity, not `==`: two `user` records for the
      # same person are equal hashes.
      def buffered?(exe, record)
        exe.records.any? { |buffered| buffered.equal?(record) }
      end

      def mark_seen(key, now)
        @seen[key] = now
        @seen.delete(@seen.keys.first) if @seen.size > 10_000
      end
    end
  end
end
