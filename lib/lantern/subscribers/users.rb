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

      def remember(details)
        @seen ||= {}
        key = details[:id]
        now = Clock.now
        return if @seen[key] && now - @seen[key] < 3600
        @seen[key] = now
        @seen.delete(@seen.keys.first) if @seen.size > 10_000
        Lantern.record(:user, id: details[:id], name: details[:name], email: details[:email], tenant: Context.current_tenant)
      end
    end
  end
end
