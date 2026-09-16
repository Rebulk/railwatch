# frozen_string_literal: true

module Railwatch
  # The platform's EnvironmentScoped concern with the account lookup replaced
  # by the embedded singleton. Everything below the seam is the platform's code.
  module EnvironmentScoped
    extend ActiveSupport::Concern

    WINDOWS = { "1h" => 1.hour, "6h" => 6.hours, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    MAX_CUSTOM_RANGE = 90.days

    included do
      before_action :set_environment
      inertia_share environment: -> { environment_props }
      inertia_share window: -> { window_key }
      inertia_share range: -> { from, to = window_range; { from: from.iso8601(6), to: to.iso8601(6) } }
      inertia_share saved_views: -> { SavedView.props_for(environment, ::Current.user) }
    end

    private

    attr_reader :environment

    def set_environment
      @environment = ::Environment.find(params[:environment_id] || ::Environment::ID)
    end

    def window_key
      custom_range ? "custom" : (WINDOWS.key?(params[:window].to_s) ? params[:window].to_s : "24h")
    end

    def window_range
      return @window_range if defined?(@window_range)
      @window_range = custom_range || begin
        key = WINDOWS.key?(params[:window].to_s) ? params[:window].to_s : "24h"
        to = Time.current
        [ to - WINDOWS[key], to ]
      end
    end

    def custom_range
      return @custom_range if defined?(@custom_range)
      from = parse_time(params[:from])
      to = from && (parse_time(params[:to]) || Time.current)
      valid = from && to && to > from && (to - from) <= MAX_CUSTOM_RANGE
      @custom_range = valid ? [ from, to ] : nil
    end

    def parse_time(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def previous_window_range
      from, to = window_range
      span = to - from
      [ from - span, from ]
    end

    def telemetry(&block) = environment.with_telemetry(&block)

    def telemetry_cursor_context(resource)
      from, to = window_range
      FilterQuery.cursor_context(environment_id: environment.id, resource: resource, query: params[:q], window: [ from.iso8601(6), to.iso8601(6) ])
    end

    def application = ::Application.current

    def environment_props
      { id: environment.id, name: environment.name, slug: environment.slug, application_id: application.id,
        application_name: application.name, issue_prefix: application.issue_prefix, last_seen_at: environment.last_seen_at,
        paused: false, token_prefix: environment.token_prefix,
        repository_url: application.repository_url, default_branch: application.default_branch }
    end

    def deploys_in_window
      environment.deploys.between(*window_range).recent.limit(50).map { |d| { deploy: d.deploy, ref: d.short_ref, at: d.deployed_at } }
    end

    def series(record_type, group_hash: nil, name: nil)
      from, to = window_range
      Telemetry::Aggregations.series(environment, record_type, from: from, to: to, group_hash: group_hash, name: name)
    end

    def grouped(record_type, limit: 100, order: nil, dir: nil)
      from, to = window_range
      Telemetry::Aggregations.grouped(environment, record_type, from: from, to: to, limit: limit, order: order, dir: dir)
    end

    def summary_with_delta(record_type, group_hash: nil)
      from, to = window_range
      previous_from, previous_to = previous_window_range
      Telemetry::Aggregations.summary_with_delta(environment, record_type, from: from, to: to,
                                                  previous_from: previous_from, previous_to: previous_to, group_hash: group_hash)
    end
  end
end
