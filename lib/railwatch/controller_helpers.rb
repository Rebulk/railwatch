# frozen_string_literal: true

module Railwatch
  # Adds `railwatch_sample` to controllers (route-level sampling, like
  # Nightwatch's Sample middleware) and captures the Inertia component name
  # when the app renders through inertia_rails.
  module ControllerHelpers
    extend ActiveSupport::Concern

    class_methods do
      # railwatch_sample 0.1, only: :index
      def railwatch_sample(rate, **options)
        before_action(**options) { Railwatch.sample(rate) }
      end

      def railwatch_never_sample(**options)
        before_action(**options) { Railwatch.dont_sample }
      end
    end
  end
end
