# frozen_string_literal: true

module Railwatch
    class MailsController < DashboardController
    def index
      fields = FilterQuery.parse(params[:q]).fetch(:fields)
      rows = telemetry do
        scope = Telemetry::Mail.between(*window_range)
        scope = scope.where(mailer: fields["mailer"]) if fields["mailer"].present?
        # Mail rows have no "kind" column; delivery_method (smtp/test/deliver_later
        # etc.) is the closest fit for a kind: filter token.
        scope = scope.where(delivery_method: fields["kind"]) if fields["kind"].present?
        scope.recent.limit(200).to_a
      end
      render inertia: { mailers: grouped("mail", limit: 100), series: series("mail"), q: params[:q].to_s,
                        recent: rows.map { |m| { id: m.id, mailer: m.mailer, subject: m.subject, to: m.to, cc: m.cc, bcc: m.bcc, attachments: m.attachments, delivery_method: m.delivery_method, duration: m.duration_ms.round(1), failed: m.failed, occurred_at: m.occurred_at, execution_id: m.execution_id, execution_preview: m.execution_preview } } }
    end
    end
end
