# frozen_string_literal: true

module Railwatch
    class SpansController < DashboardController
    def index
      spans = grouped("span", limit: 200, order: params[:sort], dir: params[:dir])
      spans = apply_filters(spans, FilterQuery.parse(params[:q]).fetch(:fields))
      render inertia: { spans: spans, series: series("span"), summary: summary_with_delta("span"),
                        sort: params[:sort] || "count", dir: params[:dir] || "desc", q: params[:q].to_s }
    end

    def show
      group_hash = params[:id]
      rows = telemetry { Telemetry::Span.where(group_hash: group_hash).between(*window_range).recent.limit(200).to_a }
      render inertia: {
        group_hash: group_hash,
        name: rows.first&.name || telemetry { Telemetry::Rollup.for_type("span").where(group_hash: group_hash).pick(:name) },
        summary: summary_with_delta("span", group_hash: group_hash), series: series("span", group_hash: group_hash),
        facets: attribute_facets(rows), samples: rows.first(50).map { |s| span_row(s) }
      }
    end

    private

    # Rollup rows for "span" carry the span name and a failure count, so
    # status:failed is "this group failed at least once in the window" rather
    # than a per-span lookup.
    def apply_filters(spans, fields)
      spans = spans.select { |s| s[:name].to_s.include?(fields["name"]) } if fields["name"].present?
      spans = spans.select { |s| s[:errors].positive? } if fields["status"] == "failed"
      spans
    end

    # Which attribute keys these spans carry, and the most common values for
    # each -- the span equivalent of the query page's "called from" breakdown.
    def attribute_facets(rows)
      rows.flat_map { |r| r.payload.to_a }.group_by(&:first).map { |key, pairs|
        { key: key, count: pairs.size, values: pairs.map { |_k, value| value.to_s }.tally.sort_by { |_v, c| -c }.first(5) }
      }.sort_by { |facet| -facet[:count] }.first(10)
    end

    def span_row(s)
      { id: s.id, name: s.name, duration: s.duration_ms.round(3), status: s.status, attributes: s.payload,
        occurred_at: s.occurred_at, execution_id: s.execution_id, execution_preview: s.execution_preview }
    end
    end
end
