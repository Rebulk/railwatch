# frozen_string_literal: true

module Railwatch
    class TransactionsController < DashboardController
    def index
      from, to = window_range
      rows = grouped("transaction", limit: 200, order: params[:sort], dir: params[:dir])
      recent = telemetry { Telemetry::Transaction.between(from, to).recent.limit(50).map { |t| transaction_row(t) } }
      render inertia: { transactions: rows, series: series("transaction"), recent: recent,
                        sort: params[:sort] || "count", dir: params[:dir] || "desc" }
    end

    private

    def transaction_row(t)
      { id: t.id, outcome: t.outcome, connection: t.connection, duration: t.duration_ms.round(3), statement_count: t.statement_count, occurred_at: t.occurred_at,
        execution_id: t.execution_id, execution_source: t.execution_source, execution_preview: t.execution_preview,
        group_hash: t.group_hash }
    end
    end
end
