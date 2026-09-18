# frozen_string_literal: true

module Railwatch
  # Live dashboard updates: Ingest::Batch broadcasts "ingested" on
  # environment_<id> after each write (throttled to one per 2 s), and the
  # page reloads its props. Under HTTP Basic the browser sends the same
  # Authorization header on the WebSocket handshake, so the channel checks
  # the same credentials as the pages; with Basic off the host's routes
  # constraint or base controller is the gate and the channel is open, as
  # the mount is.
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
