# frozen_string_literal: true

module Railwatch
    class OutgoingRequestsController < DashboardController
    def index
      fields = FilterQuery.parse(params[:q]).fetch(:fields)
      rows = telemetry do
        scope = Telemetry::OutgoingRequest.between(*window_range)
        scope = scope.where("host LIKE ?", "%#{Telemetry::OutgoingRequest.sanitize_sql_like(fields['host'])}%") if fields["host"].present?
        if (range = FilterQuery.status_range(fields["status"]))
          scope = scope.where(status_code: range)
        end
        scope.recent.limit(200).to_a
      end
      render inertia: { hosts: grouped("outgoing_request", limit: 100), series: series("outgoing_request"), q: params[:q].to_s,
                        recent: rows.map { |r| { id: r.id, host: r.host, method: r.method, url: r.url, status_code: r.status_code, duration: r.duration_ms.round(1), request_size: r.request_size, response_size: r.response_size, error: r.error, source: r.source, occurred_at: r.occurred_at, execution_id: r.execution_id, execution_preview: r.execution_preview, response_body: r.response_body } } }
    end
    end
end
