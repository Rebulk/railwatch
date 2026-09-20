# frozen_string_literal: true

module Railwatch
  # Live dashboard updates: Ingest::Batch broadcasts "ingested" on
  # environment_<id> after each write (throttled to one per 2 s), and the
  # page reloads its props. Under HTTP Basic the browser sends the same
  # Authorization header on the WebSocket handshake, so the channel checks
  # the same credentials as the pages.
  #
  # With Basic off, Configuration#dashboard_channel_allowed? asks whichever
  # gate the host declared: a dashboard_user resolver can refuse this
  # request, a named base controller or an explicit dashboard_open is taken
  # at its word, and an undeclared gate refuses. That last case matters
  # because Action Cable runs on the host's own /cable endpoint: a routes
  # constraint around the engine's mount does not cover it and a base
  # controller cannot reach it, so "something in front of /railwatch" is not
  # evidence about this. What a subscriber would see is the ingest ping (a
  # timestamp and per-type counts), never telemetry records.
  class EnvironmentChannel < ActionCable::Channel::Base
    def subscribed
      if params[:id].to_i == Environment::ID && Railwatch.config.dashboard_channel_allowed?(connection_request)
        stream_from "environment_#{Environment::ID}"
      else
        reject
      end
    end

    private

    # Built from the connection's env rather than asking it for its request:
    # ActionCable::Connection::Base#request is private (Rails documents it for
    # use inside a Connection subclass, not from a channel), so the obvious
    # call raises NoMethodError, every subscribe fails, and the dashboard sits
    # on "Disconnected" retrying forever. `env` is public and carries
    # everything a gate reads -- the Authorization header for HTTP Basic, the
    # cookies a dashboard_user resolver looks at.
    def connection_request = ActionDispatch::Request.new(connection.env)
  end
end
