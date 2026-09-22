# frozen_string_literal: true

module Railwatch
  class MonitoringHealthController < DashboardController
    def show
      render inertia: { monitoring_health: MonitoringHealth.new(environment, host: :embedded).to_h }
    end
  end
end
