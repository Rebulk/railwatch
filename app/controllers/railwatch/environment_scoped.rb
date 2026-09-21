# frozen_string_literal: true

module Railwatch
  # The platform's EnvironmentScoped concern with the account lookup replaced
  # by the embedded singleton. Everything below the seam is the platform's code.
  module EnvironmentScoped
    extend ActiveSupport::Concern

    included do
      before_action :set_environment
      inertia_share environment: -> { environment_props }
      inertia_share window: -> { window.key }
      inertia_share range: -> { window.to_h }
      inertia_share step: -> { step_key }
      inertia_share steps: -> { Telemetry::Aggregations.steps_for(*window_range) }
      inertia_share saved_views: -> { SavedView.props_for(environment, Viewer.user) }
    end

    private

    attr_reader :environment

    def set_environment
      @environment = Environment.find(params[:environment_id] || Environment::ID)
    end

    def window
      @window ||= Window.parse(window: params[:window], from: params[:from], to: params[:to])
    end

    def window_range = window.range

    # The chart bucket width: ?step= when it is one the window offers, else the
    # window's default (a minute for an hour, an hour for a day, and so on).
    def step_key
      return @step_key if defined?(@step_key)
      from, to = window_range
      offered = Telemetry::Aggregations.steps_for(from, to)
      @step_key = offered.include?(params[:step].to_s) ? params[:step].to_s : Telemetry::Aggregations.default_step(from, to)
    end

    def telemetry(&block) = environment.with_telemetry(&block)

    def telemetry_cursor_context(resource)
      from, to = window_range
      FilterQuery.cursor_context(environment_id: environment.id, resource: resource, query: params[:q], window: [ from.iso8601(6), to.iso8601(6) ])
    end

    def application = Application.current

    def environment_props
      { id: environment.id, name: environment.name, slug: environment.slug, application_id: application.id,
        application_name: application.name, issue_prefix: application.issue_prefix, last_seen_at: environment.last_seen_at,
        paused: false, token_prefix: environment.token_prefix,
        repository_url: application.repository_url, default_branch: application.default_branch }
    end

    def deploys_in_window
      environment.deploys.between(*window_range).recent.limit(50).map { |d| { deploy: d.deploy, ref: d.short_ref, at: d.deployed_at } }
    end

    # Time-bucketed series for charts, one point per step_key across the
    # window: [{t, count, errors, client_errors, avg, p50, p95, p99}]
    def series(record_type, group_hash: nil)
      from, to = window_range
      Telemetry::Aggregations.series(environment, record_type, from: from, to: to, group_hash: group_hash, step: step_key)
    end

    def grouped(record_type, limit: 100, order: nil, dir: nil)
      from, to = window_range
      Telemetry::Aggregations.grouped(environment, record_type, from: from, to: to, limit: limit, order: order, dir: dir)
    end

    def summary_with_delta(record_type, group_hash: nil)
      from, to = window_range
      previous_from, previous_to = window.previous.range
      Telemetry::Aggregations.summary_with_delta(environment, record_type, from: from, to: to,
                                                  previous_from: previous_from, previous_to: previous_to, group_hash: group_hash)
    end
  end
end
