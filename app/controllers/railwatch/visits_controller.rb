# frozen_string_literal: true

module Railwatch
    class VisitsController < DashboardController
    # Vitals come from raw visit rows (rollups only carry the visit duration),
    # so cap how many we read for a p75.
    MAX_VITAL_SAMPLES = 50_000

    def index
      fields = FilterQuery.parse(params[:q]).fetch(:fields)
      rows, vitals, component_vitals = telemetry do
        scope = Telemetry::Visit.between(*window_range)
        recent = fields["component"].present? ? scope.where(component: fields["component"]) : scope
        [ recent.recent.limit(200).to_a, web_vitals(scope), component_web_vitals(scope) ]
      end
      components = grouped("visit", limit: 100, order: params[:sort], dir: params[:dir])
        .map { |row| row.merge(component_vitals.transform_values { |p75s| p75s[row[:name]] }) }
      render inertia: { components: components, series: series("visit"), vitals: vitals,
                        sort: params[:sort] || "count", dir: params[:dir] || "desc", q: params[:q].to_s,
                        recent: rows.map { |v| { id: v.id, component: v.component, url: v.url, method: v.method, duration: v.duration_ms.round(1), status: v.status, partial: v.partial, only: v.only, props_bytes: v.props_bytes, occurred_at: v.occurred_at, user_ref: v.user_ref, lcp: v.lcp, cls: v.cls, inp: v.inp, ttfb: v.ttfb } } }
    end

    private

    # p75 of each web vital in the window, with its rating and sample count.
    # Metrics nobody reported are left out entirely.
    def web_vitals(scope)
      Telemetry::Visit::VITALS.keys.filter_map { |metric|
        values = samples(scope, metric).pluck(metric)
        next if values.empty?
        value = p75(values)
        [ metric, { value: value, rating: Telemetry::Visit.rating(metric, value), samples: values.size } ]
      }.to_h
    end

    # { lcp: { "widgets/index" => 2100 }, inp: { ... } } for the components table.
    def component_web_vitals(scope)
      %i[lcp inp].index_with do |metric|
        samples(scope, metric).pluck(:component, metric).group_by(&:first)
          .transform_values { |pairs| p75(pairs.map(&:last)) }
      end
    end

    def samples(scope, metric)
      scope.where.not(metric => nil).recent.limit(MAX_VITAL_SAMPLES)
    end

    def p75(values)
      sorted = values.sort
      sorted[[ (sorted.size * 0.75).ceil - 1, 0 ].max].round(3)
    end
    end
end
