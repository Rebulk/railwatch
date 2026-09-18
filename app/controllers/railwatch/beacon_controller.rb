# frozen_string_literal: true

require "uri"

module Railwatch
  # Receives Inertia visit timings and JavaScript errors from the browser
  # client (app/frontend/lib/railwatch.ts). Mounted at /railwatch/beacon.
  class BeaconController < ActionController::API
    # Core Web Vitals ceilings. Anything beyond these is a broken clock or a
    # forged beacon, not a page load, so it is clamped rather than stored.
    MAX_METRIC_MS = 120_000
    MAX_CLS = 100.0

    MAX_REQUEST_BYTES = 256 * 1024
    MAX_VISITS = 50
    MAX_ERRORS = 50
    MAX_ERROR_MESSAGE = 1024
    MAX_ERROR_STACK = 8192
    MAX_BREADCRUMBS = 20
    MAX_CRUMB_TEXT = 500
    MAX_CONTEXT_KEYS = 20
    MAX_CONTEXT_VALUE = 4096
    CRUMB_KINDS = %w[console click navigate].freeze

    RATE_LIMIT_WINDOW = 60 # seconds

    before_action :limit_payload, :verify_origin, :throttle, if: -> { Railwatch.config.beacon_enabled }

    def create
      return head :no_content unless Railwatch.config.beacon_enabled

      visits = params[:visits].is_a?(Array) ? params[:visits].first(MAX_VISITS).filter_map { |visit| object(visit) } : []
      user_id = Subscribers::Users.resolve_beacon_id(request)
      tenant = beacon_tenant(params[:tenant])
      record_session(params[:session], visits, user_id, tenant)
      record_errors(params[:errors], user_id, tenant)
      visits.each do |v|
        Railwatch.record(:visit,
          group: Record.group_hash(safe_string(v["component"], 255)),
          timestamp: safe_float(v["started_at"]) / 1000.0,
          component: safe_string(v["component"], 255),
          url: safe_string(v["url"], 2048),
          method: safe_string(v["method"], 10),
          duration: (safe_float(v["duration_ms"]) * 1000).round,
          status: safe_string(v["status"], 20),
          partial: v["partial"] ? true : false,
          only: array(v["only"]).first(50).map { |value| safe_string(value, 255) },
          props_bytes: safe_integer(v["props_bytes"]),
          lcp: metric_ms(v["lcp"]),
          cls: cumulative_layout_shift(v["cls"]),
          inp: metric_ms(v["inp"]),
          ttfb: metric_ms(v["ttfb"]),
          user: user_id,
          tenant: tenant,
          user_agent: safe_string(request.user_agent, 256))
      end
      head :no_content
    rescue StandardError => error
      # The endpoint is unauthenticated and its payload is untrusted. A bad
      # shape must not turn into an exception in the customer application.
      Railwatch.debug { "discarded invalid beacon payload: #{error.class}: #{error.message}" }
      head :no_content
    end

    private

    # The beacon takes no credential and keeps every browser error it is
    # sent, so a client that is not the page -- a script, a bored visitor
    # with curl -- could otherwise fill the app's quota with junk issues.
    # Two ceilings, both counters in the app's cache store in the shape of
    # Rails' own rate_limit: one per client IP, and one for the endpoint as a
    # whole so a rotating address cannot multiply its way past the first.
    # Read from config per request, so an initializer can raise or remove
    # either one.
    # Same idea as Sentry's allowed domains: a public ingest endpoint cannot
    # authenticate its caller (the credential would be in the page), so it
    # refuses anything that says it came from somewhere else. Not a security
    # boundary -- an Origin header is trivially forged outside a browser --
    # but it stops another site's page from spending this app's quota.
    # Missing Origin and Referer pass, which is how Rails' own forgery origin
    # check behaves.
    def verify_origin
      origin = request.origin || referer_origin
      return if origin.nil? || origin == request.base_url
      return if Railwatch.config.beacon_allowed_origins.any? { |allowed| origin_matches?(origin, allowed) }

      Railwatch.debug { "refused a beacon from #{origin} (this app is #{request.base_url})" }
      head :forbidden
    end

    def referer_origin
      referer = request.referer.presence or return nil
      uri = URI.parse(referer)
      return nil unless uri.scheme && uri.host

      port = ":#{uri.port}" if uri.port && uri.port != uri.default_port
      "#{uri.scheme}://#{uri.host}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    # An entry is either a full origin ("https://app.example.com") or a bare
    # host, which matches either scheme.
    def origin_matches?(origin, allowed)
      return true if origin == allowed

      allowed.include?("://") ? false : [ "https://#{allowed}", "http://#{allowed}" ].include?(origin)
    end

    def throttle
      limit = Railwatch.config.beacon_rate_limit.to_i
      global = Railwatch.config.beacon_global_rate_limit.to_i
      return refuse_beacon if global.positive? && over?("railwatch:beacon:all", global)
      return unless limit.positive?

      # A store that cannot count (NullStore, a cache that is down, one whose
      # increment is unsupported) returns nil. Refuse the beacon then rather
      # than serving an unauthenticated, unlimited write endpoint: the
      # browser client retries on the next flush, and an app that genuinely
      # wants no limit sets beacon_rate_limit to 0.
      refuse_beacon if over?("railwatch:beacon:#{request.remote_ip}", limit)
    end

    # True when this key has passed its ceiling for the window, and also when
    # the store cannot count at all: a store that returns nil (NullStore, a
    # cache that is down, one without increment) would otherwise leave an
    # unauthenticated endpoint with no ceiling on it. An app that genuinely
    # wants no limit sets the limit to 0, or turns the beacon off.
    def over?(key, limit)
      count = cache_store.increment(key, 1, expires_in: RATE_LIMIT_WINDOW)
      if count.nil?
        Railwatch.debug { "beacon rate limiting is unavailable (#{cache_store.class}); refusing the beacon" }
        return true
      end
      count > limit
    end

    def refuse_beacon
      response.set_header("Retry-After", RATE_LIMIT_WINDOW.to_s)
      head :too_many_requests
    end

    def limit_payload
      head :content_too_large if request.raw_post.bytesize > MAX_REQUEST_BYTES
    end

    # The browser half of release health: one `session` record per beacon
    # flush, never more, whatever the flush carried. The first one the client
    # sends has no duration yet and opens the session; every later flush
    # beats it along; the pagehide flush closes it with `ended`.
    def record_session(session, visits, user_id, tenant)
      session = object(session)
      return unless session

      id = safe_string(session["id"], 64)
      return if id.empty?

      duration_ms = session["duration_ms"]
      Railwatch.record(:session,
        group: Record.group_hash(id),
        id: id,
        source: "browser",
        status: duration_ms.nil? ? "started" : "ok",
        started_at: safe_float(session["started_at"]) / 1000.0,
        duration: duration_ms.nil? ? nil : (safe_float(duration_ms) * 1000).round,
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
      Railwatch.keep!
      origin = request.base_url
      session_id = session_id_from(params[:session])
      errors.each do |error|
        error = object(error)
        next unless error
        name = safe_string(error["name"], 255)
        next if name.empty?
        record_error(error, name, origin, session_id, user_id, tenant)
      end
    end

    # The tenant the browser says it was looking at. The beacon does not go
    # through whatever path or subdomain the app scopes tenants by, so an
    # app that scopes them at all resolves nothing here -- the client's hint
    # (startRailwatch({ tenant })) fills that gap, and never overrides a
    # tenant the server did resolve for itself.
    def beacon_tenant(hint)
      Context.current_tenant || (hint.is_a?(String) ? safe_string(hint, 255).presence : nil)
    end

    # The tab's session id, so a browser error can be lined up with the
    # session it crashed. Shaped like every other read off this payload:
    # anything but a hash carrying an id yields no id at all.
    def session_id_from(session)
      session = object(session)
      session ? safe_string(session["id"], 64) : ""
    end

    def record_error(error, name, origin, session_id, user_id, tenant)
      message = safe_string(error["message"], MAX_ERROR_MESSAGE)
      frames = Backtrace.js_frames(safe_string(error["stack"], MAX_ERROR_STACK), origin: origin)
      top = Subscribers::Exceptions.top_frame(frames)
      parts = Subscribers::Exceptions.cap_fingerprint(
        [ name, top[:file], top[:line], Subscribers::Exceptions.normalize_message(message) ])
      Railwatch.record(:exception,
        group: Record.group_hash(*parts),
        timestamp: safe_float(error["at"]).positive? ? safe_float(error["at"]) / 1000.0 : nil,
        class: name,
        message: message,
        handled: false,
        severity: "error",
        source: "browser",
        file: top[:file],
        line: top[:line],
        frames: frames,
        context: Context.serialized_with(error_context(error["context"]).merge(browser: {
          url: safe_string(error["url"], 2048).presence,
          component: safe_string(error["component"], 255).presence,
          visit: safe_string(error["visit"], 2048).presence,
          session: session_id.presence,
          user_agent: safe_string(request.user_agent, 256).presence,
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
        crumb = object(crumb)
        next unless crumb
        kind = safe_string(crumb["kind"], 20)
        next unless CRUMB_KINDS.include?(kind)
        text = safe_string(crumb["text"], MAX_CRUMB_TEXT)
        next if text.empty?
        { at: safe_float(crumb["at"]), kind: kind, text: text }
      end
    end

    # Whatever the app handed Railwatch's reportError -- a React error
    # boundary's component stack, most often. Flattened to strings so a
    # cyclic or enormous object cannot ride in on it.
    def error_context(raw)
      raw = object(raw)
      return {} unless raw
      raw.first(MAX_CONTEXT_KEYS).to_h do |key, value|
        [ safe_string(key, 64), safe_string(value, MAX_CONTEXT_VALUE) ]
      end
    end

    # Web vitals only ride along on the initial-load visit, and only from
    # browsers that support the entry type behind them, so every one of these
    # is nil far more often than not.
    def metric_ms(value)
      return nil if value.nil? || value == ""
      safe_float(value).round.clamp(0, MAX_METRIC_MS)
    end

    def cumulative_layout_shift(value)
      return nil if value.nil? || value == ""
      safe_float(value).clamp(0.0, MAX_CLS).round(4)
    end

    def object(value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value if value.is_a?(Hash)
    end

    def array(value)
      value.is_a?(Array) ? value : []
    end

    def safe_string(value, length)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)[0, length]
    rescue StandardError
      ""
    end

    def safe_float(value)
      Float(value, exception: false).to_f
    rescue StandardError
      0.0
    end

    def safe_integer(value)
      Integer(value, exception: false).to_i
    rescue StandardError
      0
    end
  end
end
