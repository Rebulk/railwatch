# frozen_string_literal: true

module Nightrail
  # Adds `nightrail_sample` to controllers (route-level sampling, like
  # Nightwatch's Sample middleware) and captures the Inertia component name
  # when the app renders through inertia_rails.
  module ControllerHelpers
    extend ActiveSupport::Concern

    class_methods do
      # nightrail_sample 0.1, only: :index
      def nightrail_sample(rate, **options)
        before_action(**options) { Nightrail.sample(rate) }
      end

      def nightrail_never_sample(**options)
        before_action(**options) { Nightrail.dont_sample }
      end
    end
  end
end
