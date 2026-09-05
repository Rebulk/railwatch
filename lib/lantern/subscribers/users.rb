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

      # One `user` entity per id per process-hour. Each overlapping execution
      # keeps a fallback record until it knows it will ship. At reporter
      # handoff, a process-wide reservation lets exactly one of those records
      # through; the rest are removed from their execution buffers. If every
      # occurrence is sampled out, paused, redacted, or dropped by the record
      # limit, no reservation is committed and the next sighting stays
      # eligible.
      def remember(details)
        key = details[:id]
        now = Clock.now
        return if seen_recently?(key, now)

        exe = execution
        pending = exe&.pending_users
        return if pending&.key?(key)

        if exe
          record = Lantern.record(:user, id: key, name: details[:name], email: details[:email],
                                  tenant: Context.current_tenant)
          return unless record

          (exe.pending_users ||= {})[key] = record
          record
        else
          token = Object.new
          claims = { token: token, keys: [ key ] }

          begin
            return unless claim!(key, token)

            record = Lantern.record(:user, id: key, name: details[:name], email: details[:email],
                                    tenant: Context.current_tenant)
            commit_standalone!(key, token, record, now)
            record
          ensure
            release_execution!(claims)
          end
        end
      end

      # Called immediately before Lantern.finish_execution hands a tree to the
      # reporter. It first settles late-bound tenant references, then waits for
      # an overlapping handoff and either owns each final reference or removes
      # this execution's now-duplicate buffered record.
      def prepare_execution!(exe)
        pending = exe.pending_users
        exe.pending_users = nil
        token = Object.new
        claims = { token: token, keys: [] }

        begin
          # Claim in a stable order so two executions that observed several
          # users in opposite orders cannot wait on one another.
          entries = pending.filter_map do |key, record|
            next unless buffered?(exe, record)

            [ Execution.qualified_user(key, exe.tenant), record ]
          end
          entries.sort_by { |reference, _record| reference }.each do |reference, record|
            if claim!(reference, token, claimed_keys: claims[:keys])
              record[:id] = reference
              record[:tenant] = exe.tenant if record[:tenant].nil?
            else
              exe.delete_buffered_record(record)
            end
          end

          yield claims
        ensure
          release_execution!(claims)
        end
      end

      # Commit only after reporter.write accepted the complete execution tree.
      def commit_execution!(claims)
        return unless claims

        state_mutex.synchronize do
          claims[:keys].each do |key|
            next unless inflight[key].equal?(claims[:token])

            mark_seen(key, Clock.now)
            inflight.delete(key)
          end
          state_condition.broadcast
        end
      end

      # A reporter failure must not leave a waiter blocked or suppress a later
      # sighting. Safe to call after commit; committed claims are already gone.
      def release_execution!(claims)
        return unless claims

        state_mutex.synchronize do
          claims[:keys].each do |key|
            inflight.delete(key) if inflight[key].equal?(claims[:token])
          end
          state_condition.broadcast
        end
      end

      def discard_execution!(exe)
        exe.pending_users = nil
      end

      # A fork inherits this cache but not the reporter buffer the cached
      # entities were written to, so the child has to emit its own.
      def restart_after_fork!
        @seen = {}
        @inflight = {}
        @state_mutex = Mutex.new
        @state_condition = ConditionVariable.new
        execution&.pending_users = nil
      end

      # A record rejected by the execution limit, or shifted out of a
      # failure-context ring, cannot reserve its user reference.
      def buffered?(exe, record)
        exe.records.any? { |buffered| buffered.equal?(record) }
      end

      def seen_recently?(key, now)
        state_mutex.synchronize { seen_recently_locked?(key, now) }
      end

      def seen_recently_locked?(key, now)
        last = seen[key]
        last && now - last < 3600
      end

      def claim!(key, token, claimed_keys: nil)
        state_mutex.synchronize do
          while (owner = inflight[key]) && !owner.equal?(token)
            state_condition.wait(state_mutex)
          end
          return false if owner&.equal?(token)
          return false if seen_recently_locked?(key, Clock.now)

          # Track ownership before publishing it. If an asynchronous
          # exception lands between these statements, release_execution!
          # either finds no matching claim or has the key needed to remove it.
          claimed_keys << key if claimed_keys
          inflight[key] = token
          true
        end
      end

      # Standalone user records are written synchronously, outside an
      # execution. Fence the cache update too, without holding the mutex while
      # reporter/redactor code runs.
      def commit_standalone!(key, token, record, now)
        state_mutex.synchronize do
          mark_seen(key, now) if record && inflight[key].equal?(token)
          inflight.delete(key) if inflight[key].equal?(token)
          state_condition.broadcast
        end
      end

      def mark_seen(key, now)
        seen[key] = now
        seen.delete(seen.keys.first) if seen.size > 10_000
      end

      def seen
        @seen ||= {}
      end

      def inflight
        @inflight ||= {}
      end

      def state_mutex
        @state_mutex ||= Mutex.new
      end

      def state_condition
        @state_condition ||= ConditionVariable.new
      end
    end
  end
end
