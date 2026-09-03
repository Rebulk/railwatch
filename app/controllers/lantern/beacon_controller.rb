# frozen_string_literal: true

module Lantern
  # Receives Inertia visit timings from the browser client
  # (app/frontend/lib/lantern.ts). Mounted at /lantern/beacon.
  class BeaconController < ActionController::API
    def create
      return head :no_content unless Lantern.config.beacon_enabled

      visits = Array(params[:visits]).first(50)
      user_id = Subscribers::Users.resolve_id(request.env)
      visits.each do |v|
        v = v.to_unsafe_h if v.respond_to?(:to_unsafe_h)
        Lantern.record(:visit,
          group: Record.group_hash(v["component"].to_s),
          timestamp: v["started_at"].to_f / 1000.0,
          component: v["component"].to_s[0, 255],
          url: v["url"].to_s[0, 2048],
          method: v["method"].to_s[0, 10],
          duration: (v["duration_ms"].to_f * 1000).round,
          status: v["status"].to_s[0, 20],
          partial: v["partial"] ? true : false,
          only: Array(v["only"]).map(&:to_s).first(50),
          props_bytes: v["props_bytes"].to_i,
          user: user_id,
          tenant: Context.current_tenant,
          user_agent: request.user_agent.to_s[0, 256])
      end
      head :no_content
    end
  end
end
