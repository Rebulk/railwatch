# frozen_string_literal: true

module Railwatch
    class LogsController < DashboardController
    def index
      from, to = window_range
      parsed = FilterQuery.parse(params[:q])
      page_data = nil
      page = lambda do
        page_data ||= telemetry do
          filtered = FilterQuery.apply(Telemetry::Log.all, resource: :logs, query: params[:q], from: from, to: to)
          rows, meta = Telemetry::CursorPage.call(filtered, cursor: params[:cursor], limit: params[:limit],
            context: telemetry_cursor_context(:logs))
          [ rows.map { |l| log_row(l) }, meta, Telemetry::Log.fts_snippets(rows.map(&:id), parsed[:text]) ]
        end
      end
      render inertia: {
        logs: InertiaRails.merge { page.call[0] }, pagination: -> { page.call[1] },
        counts: -> { level_counts(from, to) }, highlights: InertiaRails.deep_merge { page.call[2] }, q: params[:q].to_s
      }
    end

    private

    # The level facet counts the same rows the search does, except for the
    # selected level itself, so switching level never disagrees with the table.
    def level_counts(from, to)
      telemetry do
        FilterQuery.apply(Telemetry::Log.all, resource: :logs, query: params[:q], from: from, to: to,
          except: %w[level status]).group(:level).count
      end
    end

    def log_row(log)
      { id: log.id, level: log.level, message: log.message.first(2000), tags: log.tags, occurred_at: log.occurred_at,
       execution_id: log.execution_id, execution_source: log.execution_source, execution_preview: log.execution_preview,
       source: log.source, tenant: log.app_tenant, user_ref: log.user_ref, context: log.context }
    end
    end
end
