# frozen_string_literal: true

module Railwatch
  # A named, shareable filter on one environment page: "5xx checkout requests",
  # "acme tenant logs". Pinned views appear in the sidebar under the page.
  class SavedView < ApplicationRecord
    self.table_name = "railwatch_saved_views"
    # page => the index route helper the view links back to. The link is built
    # server-side so the sidebar, the menu, and a pasted URL all agree.
    PAGE_PATHS = {
      "requests" => :application_environment_requests_path,
      "jobs" => :application_environment_jobs_path,
      "scheduled_tasks" => :application_environment_scheduled_tasks_path,
      "commands" => :application_environment_commands_path,
      "exceptions" => :application_environment_exceptions_path,
      "queries" => :application_environment_queries_path,
      "spans" => :application_environment_spans_path,
      "logs" => :application_environment_logs_path,
      "visits" => :application_environment_visits_path,
      "people" => :application_environment_people_path,
      "tenants" => :application_environment_tenants_path,
      "llm_calls" => :application_environment_llm_calls_path,
      "outgoing_requests" => :application_environment_outgoing_requests_path,
      "cache_events" => :application_environment_cache_events_path,
      "mails" => :application_environment_mails_path,
      "notifications" => :application_environment_notifications_path
    }.freeze
    PAGES = PAGE_PATHS.keys.freeze

    def environment = Environment.current
    def user
      User.find_by(id: viewer_id)
    end

    def user=(u)
      self.viewer_id = u&.id&.to_s
    end

    validates :name, presence: true, length: { maximum: 80 }
    validates :page, inclusion: { in: PAGES }

    scope :pinned, -> { where(pinned: true) }
    scope :visible_to, ->(user) { where(shared: true).or(where(viewer_id: user.id.to_s)) }

    # The props every environment page shares, ready for the sidebar and the
    # Views menu: one entry per view this user is allowed to see.
    def self.props_for(environment, user)
      where(environment_id: environment.id).visible_to(user).order(:name).map { |view| view.props(environment, user) }
    end

    def props(environment, user)
      { id: id, name: name, page: page, query: query, window: window, params: params, pinned: pinned, shared: shared,
        mine: viewer_id == user&.id, url: path_for(environment) }
    end

    # This page's index path with the view's window, query, and extra params
    # (sort/dir) applied -- the shareable URL.
    def path_for(environment)
      Railwatch.url_helpers.public_send(PAGE_PATHS.fetch(page), environment.application_id, environment.id,
        { window: window.presence, q: query.presence, **params.to_h.symbolize_keys }.compact)
    end
  end
end
