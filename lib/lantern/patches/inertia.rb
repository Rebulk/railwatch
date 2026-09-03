# frozen_string_literal: true

module Lantern
  module Patches
    # Records the Inertia component and SSR time per request. inertia_rails
    # has no instrumentation of its own, so this is a small prepend on the
    # renderer; skipped entirely if the gem is not loaded.
    module Inertia
      module Renderer
        def render
          env = @request&.env
          env["lantern.inertia_component"] = @component.to_s if env
          super
        end
      end

      def self.install!
        return unless defined?(::InertiaRails::Renderer)
        ::InertiaRails::Renderer.prepend(Renderer) unless ::InertiaRails::Renderer.ancestors.include?(Renderer)
      end
    end
  end
end
