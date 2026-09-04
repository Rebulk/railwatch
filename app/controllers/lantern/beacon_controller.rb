# frozen_string_literal: true

module Lantern
  # Receives Inertia visit timings and JavaScript errors from the browser
  # client (app/frontend/lib/lantern.ts). Mounted at /lantern/beacon.
  class BeaconController < ActionController::API
    # Core Web Vitals ceilings. Anything beyond these is a broken clock or a
    # forged beacon, not a page load, so it is clamped rather than stored.
    MAX_METRIC_MS = 120_000
    MAX_CLS = 100.0

    MAX_ERRORS = 50
    MAX_ERROR_MESSAGE = 1024
    MAX_ERROR_STACK = 8192
    MAX_BREADCRUMBS = 20
    MAX_CRUMB_TEXT = 500
    MAX_CONTEXT_KEYS = 20
    MAX_CONTEXT_VALUE = 4096
    CRUMB_KINDS = %w[console click navigate].freeze

    def create
      return head :no_content unless Lantern.config.beacon_enabled

      visits = Array(params[:visits]).first(50)
      user_id = Subscribers::Users.resolve_id(request.env)
      tenant = beacon_tenant(params[:tenant])
      record_session(params[:session], visits, user_id, tenant)
      record_errors(params[:errors], user_id, tenant)
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
          lcp: metric_ms(v["lcp"]),
          cls: cumulative_layout_shift(v["cls"]),
          inp: metric_ms(v["inp"]),
          ttfb: metric_ms(v["ttfb"]),
          user: user_id,
          tenant: tenant,
          user_agent: request.user_agent.to_s[0, 256])
      end
      head :no_content
    end

    private

    # The browser half of release health: one `session` record per beacon
    # flush, never more, whatever the flush carried. The first one the client
    # sends has no duration yet and opens the session; every later flush
    # beats it along; the pagehide flush closes it with `ended`.
    def record_session(session, visits, user_id, tenant)
      return if session.blank?

      session = session.to_unsafe_h if session.respond_to?(:to_unsafe_h)
      id = session["id"].to_s[0, 64]
      return if id.empty?

      duration_ms = session["duration_ms"]
      Lantern.record(:session,
        group: Record.group_hash(id),
        id: id,
        source: "browser",
        status: duration_ms.nil? ? "started" : "ok",
        started_at: session["started_at"].to_f / 1000.0,
        duration: duration_ms.nil? ? nil : (duration_ms.to_f * 1000).round,
        visits: visits.size,
        errors: visits.count { |v| v["status"] == "error" },
        ended: session["ended"] ? true : false,
        user: user_id,
        tenant: tenant)
    end

    # One exception record per JavaScript error the page threw, filed the
    # same way the Ruby side files one: the browser's stack parsed into
    # frames, and a default fingerprint of class, top in-app frame, and the
    # message with its variable data removed, so a browser issue groups and
    # regresses like any other. Nothing here may raise on a payload the app
    # did not write: an entry that is not a hash, or carries no error name,
    # is dropped rather than answered with a 500.
    def record_errors(errors, user_id, tenant)
      errors = errors.is_a?(Array) ? errors.first(MAX_ERRORS) : []
      return if errors.empty?

      # A browser error is unhandled by definition, so it has to survive the
      # beacon request's own head sampling decision the way an unhandled
      # Ruby exception does.
      Lantern.keep!
      origin = request.base_url
      session_id = session_id_from(params[:session])
      errors.each do |error|
        error = error.to_unsafe_h if error.respond_to?(:to_unsafe_h)
        next unless error.is_a?(Hash)
        name = error["name"].to_s[0, 255]
        next if name.empty?
        record_error(error, name, origin, session_id, user_id, tenant)
      end
    end

    # The tenant the browser says it was looking at. The beacon does not go
    # through whatever path or subdomain the app scopes tenants by, so an
    # app that scopes them at all resolves nothing here -- the client's hint
    # (startLantern({ tenant })) fills that gap, and never overrides a
    # tenant the server did resolve for itself.
    def beacon_tenant(hint)
      Context.current_tenant || (hint.is_a?(String) ? hint[0, 255].presence : nil)
    end

    # The tab's session id, so a browser error can be lined up with the
    # session it crashed. Shaped like every other read off this payload:
    # anything but a hash carrying an id yields no id at all.
    def session_id_from(session)
      session = session.to_unsafe_h if session.respond_to?(:to_unsafe_h)
      session.is_a?(Hash) ? session["id"].to_s[0, 64] : ""
    end

    def record_error(error, name, origin, session_id, user_id, tenant)
      message = error["message"].to_s[0, MAX_ERROR_MESSAGE]
      frames = Backtrace.js_frames(error["stack"].to_s[0, MAX_ERROR_STACK], origin: origin)
      top = Subscribers::Exceptions.top_frame(frames)
      parts = Subscribers::Exceptions.cap_fingerprint(
        [ name, top[:file], top[:line], Subscribers::Exceptions.normalize_message(message) ])
      Lantern.record(:exception,
        group: Record.group_hash(*parts),
        timestamp: error["at"].to_f.positive? ? error["at"].to_f / 1000.0 : nil,
        class: name,
        message: message,
        handled: false,
        severity: "error",
        source: "browser",
        file: top[:file],
        line: top[:line],
        frames: frames,
        context: Context.serialized_with(error_context(error["context"]).merge(browser: {
          url: error["url"].to_s[0, 2048].presence,
          component: error["component"].to_s[0, 255].presence,
          visit: error["visit"].to_s[0, 2048].presence,
          session: session_id.presence,
          user_agent: request.user_agent.to_s[0, 256].presence,
          breadcrumbs: breadcrumbs(error["breadcrumbs"]).presence
        }.compact)),
        fingerprint: parts,
        fingerprint_source: "default",
        user: user_id,
        tenant: tenant)
    end

    # What the user did in the run-up to the crash, kept only where each
    # entry is the shape the client writes. A garbled or forged trail is
    # dropped entry by entry rather than failing the beacon.
    def breadcrumbs(raw)
      return [] unless raw.is_a?(Array)
      raw.first(MAX_BREADCRUMBS).filter_map do |crumb|
        crumb = crumb.to_unsafe_h if crumb.respond_to?(:to_unsafe_h)
        next unless crumb.is_a?(Hash)
        next unless CRUMB_KINDS.include?(crumb["kind"].to_s)
        text = crumb["text"].to_s[0, MAX_CRUMB_TEXT]
        next if text.empty?
        { at: crumb["at"].to_f, kind: crumb["kind"].to_s, text: text }
      end
    end

    # Whatever the app handed Lantern's reportError -- a React error
    # boundary's component stack, most often. Flattened to strings so a
    # cyclic or enormous object cannot ride in on it.
    def error_context(raw)
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      return {} unless raw.is_a?(Hash)
      raw.first(MAX_CONTEXT_KEYS).to_h { |key, value| [ key.to_s[0, 64], value.to_s[0, MAX_CONTEXT_VALUE] ] }
    end

    # Web vitals only ride along on the initial-load visit, and only from
    # browsers that support the entry type behind them, so every one of these
    # is nil far more often than not.
    def metric_ms(value)
      return nil if value.nil? || value == ""
      value.to_f.round.clamp(0, MAX_METRIC_MS)
    end

    def cumulative_layout_shift(value)
      return nil if value.nil? || value == ""
      value.to_f.clamp(0.0, MAX_CLS).round(4)
    end
  end
end
