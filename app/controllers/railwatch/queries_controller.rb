# frozen_string_literal: true

module Railwatch
    class QueriesController < DashboardController
    def index
      from, to = window_range
      page_data = nil
      page = lambda do
        page_data ||= telemetry do
          scope = FilterQuery.apply(Telemetry::Query.with_sql, resource: :queries, query: params[:q], from: from, to: to)
          rows, meta = Telemetry::CursorPage.call(scope, cursor: params[:cursor], limit: params[:limit], order: :slowest,
            context: telemetry_cursor_context(:queries))
          [ rows.map { |q| query_row(q) }, meta ]
        end
      end
      render inertia: {
        queries: -> { grouped("query", limit: 200, order: params[:sort], dir: params[:dir]) },
        n_plus_ones: -> { n_plus_ones(from, to) }, slowest: InertiaRails.merge { page.call.first },
        pagination: -> { page.call.last }, q: params[:q].to_s, summary: -> { summary_with_delta("query") },
        sort: params[:sort] || "count", dir: params[:dir] || "desc"
      }
    end

    def show
      group_hash = params[:id]
      rows = telemetry { Telemetry::Query.where(group_hash: group_hash).between(*window_range).recent.limit(100).with_sql.to_a }
      summary = telemetry { Telemetry::Rollup.summarize(Telemetry::Rollup.for_type("query").where(group_hash: group_hash).between(*window_range)) }
      sources = rows.filter_map(&:source).tally.sort_by { |_s, c| -c }.first(10)
      callers = rows.map(&:execution_preview).compact.tally.sort_by { |_s, c| -c }.first(10)
      render inertia: { group_hash: group_hash, sql: rows.first&.sql, summary: summary, series: series("query", group_hash: group_hash),
                        sources: sources, callers: callers, roles: rows.filter_map(&:role).tally.sort_by { |_r, c| -c },
                        explain: explain_sample(group_hash), samples: rows.first(50).map { |q| query_row(q) } }
    end

    private

    def n_plus_ones(from, to)
      telemetry do
        Telemetry::NPlusOne.between(from, to).group(:group_hash).pluck(:group_hash, Arel.sql("COUNT(*)"), Arel.sql("MAX(sql)"), Arel.sql("MAX(source)"), Arel.sql("MAX(count)"))
          .map { |g, c, sql, src, mx| { group_hash: g, occurrences: c, sql: sql, source: src, max_count: mx, suggestion: Telemetry::NPlusOne.new(sql: sql, source: src).suggestion } }
          .sort_by { |r| -r[:occurrences] }.first(50)
      end
    end

    # The newest sample in the group that the gem attached a query plan to.
    # Only slow queries get one (RAILWATCH_CAPTURE_QUERY_EXPLAIN), so this is
    # usually a different row than the newest sample overall.
    def explain_sample(group_hash)
      q = telemetry { Telemetry::Query.where(group_hash: group_hash).between(*window_range).where.not(explain: nil).recent.with_sql.first }
      return nil if q.nil?
      { plan: q.explain, occurred_at: q.occurred_at, duration: q.duration_ms.round(3), execution_id: q.execution_id }
    end

    def query_row(q)
      { id: q.id, sql: q.sql.first(300), duration: q.duration_ms.round(3), occurred_at: q.occurred_at, execution_id: q.execution_id,
        execution_preview: q.execution_preview, source: q.source, connection: q.connection, row_count: q.row_count, group_hash: q.group_hash }
    end
    end
end
