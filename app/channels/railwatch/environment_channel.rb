# frozen_string_literal: true

module Railwatch
  # Live dashboard updates: Ingest::Batch broadcasts "ingested" on
  # environment_<id> after each write (throttled to one per 2 s), and the
  # page reloads its props. Under HTTP Basic the browser sends the same
  # Authorization header on the WebSocket handshake, so the channel checks
  # the same credentials as the pages.
  #
  # With Basic off this check passes and the host's own
  # ApplicationCable::Connection is the only gate: a routes constraint around
  # the engine's mount does NOT cover the app's separate /cable endpoint, and
  # base_controller_class applies to HTTP controllers only. What a subscriber
  # can see here is the ingest ping (a timestamp and per-type counts), never
  # telemetry records, but an app that gates /railwatch and leaves /cable open
  # should know that is where the line falls.
  class EnvironmentChannel < ActionCable::Channel::Base
    def subscribed
      if params[:id].to_i == Environment::ID && Railwatch.config.http_basic_auth_ok?(connection.request)
        stream_from "environment_#{Environment::ID}"
      else
        reject
      end
    end
  end
end
