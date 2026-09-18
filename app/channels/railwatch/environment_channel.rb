# frozen_string_literal: true

module Railwatch
  # Live dashboard updates: Ingest::Batch broadcasts "ingested" on
  # environment_<id> after each write (throttled to one per 2 s), and the
  # page reloads its props. Same gate as the dashboard pages
  # (Railwatch.config.dashboard_allowed?): outside development and test the
  # host has to name who is looking, or open the dashboard on purpose.
  class EnvironmentChannel < ActionCable::Channel::Base
    def subscribed
      if params[:id].to_i == Environment::ID && Railwatch.config.dashboard_allowed?(connection.request)
        stream_from "environment_#{Environment::ID}"
      else
        reject
      end
    end
  end
end
