# frozen_string_literal: true

module Nightrail
  module Patches
    # Records the Inertia component and SSR time per request. inertia_rails
    # has no instrumentation of its own, so this is a small prepend on the
    # renderer; skipped entirely if the gem is not loaded.
    module Inertia
      module Renderer
        def render
          env = @request&.env
          env["nightrail.inertia_component"] = @component.to_s if env
          super
        end

        # Private on InertiaRails::Renderer, only called when SSR is enabled
        # and the request isn't itself an Inertia XHR visit -- so this adds
        # no cost to the common (non-SSR) render path.
        def ssr_render
          start = Clock.monotonic
          super
        ensure
          env = @request&.env
          env["nightrail.inertia_ssr_ms"] = ((Clock.monotonic - start) * 1000).round(2) if env
        end
      end

      def self.install!
        return unless defined?(::InertiaRails::Renderer)
        ::InertiaRails::Renderer.prepend(Renderer) unless ::InertiaRails::Renderer.ancestors.include?(Renderer)
      end
    end
  end
end
