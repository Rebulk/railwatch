# frozen_string_literal: true

module Railwatch
  # Live dashboard updates: Ingest::Batch broadcasts "ingested" on
  # environment_<id> after each write (throttled to one per 2 s), and the
  # page reloads its props. An embedded install has one environment and the
  # host's own auth in front of the dashboard, so subscribing is open to
  # anyone who can reach the mount.
  class EnvironmentChannel < ActionCable::Channel::Base
    def subscribed
      if params[:id].to_i == Environment::ID
        stream_from "environment_#{Environment::ID}"
      else
        reject
      end
    end
  end
end
