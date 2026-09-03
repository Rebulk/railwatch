# frozen_string_literal: true

module Lantern
  # Adds `lantern_sample` to controllers (route-level sampling, like
  # Nightwatch's Sample middleware) and captures the Inertia component name
  # when the app renders through inertia_rails.
  module ControllerHelpers
    extend ActiveSupport::Concern

    class_methods do
      # lantern_sample 0.1, only: :index
      def lantern_sample(rate, **options)
        before_action(**options) { Lantern.sample(rate) }
      end

      def lantern_never_sample(**options)
        before_action(**options) { Lantern.dont_sample }
      end
    end
  end
end
