# frozen_string_literal: true

module Railwatch
    class ViewRendersController < DashboardController
    def index
      from, to = window_range
      fields = FilterQuery.parse(params[:q]).fetch(:fields)
      rows = grouped("view_render", limit: 200, order: params[:sort], dir: params[:dir])
      rows = rows.select { |r| r[:name].include?(fields["template"]) } if fields["template"].present?
      kinds = telemetry do
        Telemetry::Rollup.for_type("view_render").between(from, to).to_a.group_by(&:group_hash)
          .transform_values { |group_rows| group_rows.max_by(&:bucket).extra["kind"] }
      end
      rows.each { |r| r[:kind] = kinds[r[:group_hash]] }
      slowest = telemetry { Telemetry::ViewRender.between(from, to).order(duration: :desc).limit(30).map { |v| render_row(v) } }
      render inertia: { renders: rows, series: series("view_render"), slowest: slowest,
                        sort: params[:sort] || "count", dir: params[:dir] || "desc", q: params[:q].to_s }
    end

    private

    def render_row(v)
      { id: v.id, identifier: v.identifier, kind: v.kind, layout: v.layout, duration: v.duration_ms.round(3),
        occurred_at: v.occurred_at, execution_id: v.execution_id, execution_source: v.execution_source,
        execution_preview: v.execution_preview, group_hash: v.group_hash }
    end
    end
end
