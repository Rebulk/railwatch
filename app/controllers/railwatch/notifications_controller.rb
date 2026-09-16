# frozen_string_literal: true

module Railwatch
    class NotificationsController < DashboardController
    def index
      rows = telemetry { Telemetry::Notification.between(*window_range).recent.limit(200).to_a }
      render inertia: { groups: grouped("notification", limit: 100),
                        recent: rows.map { |n| { id: n.id, notifier: n.notifier, delivery_method: n.delivery_method, duration: n.duration_ms.round(1), failed: n.failed, occurred_at: n.occurred_at, execution_id: n.execution_id, execution_preview: n.execution_preview } } }
    end
    end
end
