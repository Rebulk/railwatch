# frozen_string_literal: true

module Railwatch
  # Server-side sessions, the fallback half of release health. Every request
  # that resolves a user or carries the browser client's session id updates
  # one in-memory entry per session key; a background thread ships each entry
  # as a `session` record every config.session_flush_interval and retires the
  # ones idle for longer than config.session_timeout.
  #
  # Same thread shape as Railwatch::Health -- one thread per process, parked on
  # a ConditionVariable, re-armed in every forked child -- and started from
  # the same engine initializer.
  #
  # The browser client emits `session` records of its own through the beacon
  # carrying the same id (it sets the cookie this reads), so a session seen
  # from both ends dedupes on the platform instead of counting twice.
  module Sessions
    # Only a request creates a session, so a worker/console/rake process has
    # nothing to flush and does not start a thread.
    ROLES = %w[web].freeze
    # A process that keeps meeting new keys -- an app that sets no cookie
    # being crawled, say -- must not grow without bound. Oldest first, and
    # counted so the drop is visible rather than silent.
    MAX_KEYS = 10_000
    # The cookie the browser client sets (railwatch.ts), so every request from
    # a tab carries the id its beacons already use.
    COOKIE = /(?:\A|;\s*)railwatch_session=([^;]+)/
    KEY_LIMIT = 64
    # What the browser client mints for a session or a tab id. Anything else
    # in a header, cookie, or beacon is not one, and is not recorded as one.
    BROWSER_ID = /\A[A-Za-z0-9_-]{1,64}\z/
    # The id Sessions.mint handed this request, read by key_for and
    # browser_fields as if the browser had sent it.
    MINTED = "railwatch.session_id"
    # The client's idle timeout, which the cookie lapses with (railwatch.ts).
    COOKIE_MAX_AGE = 30 * 60
    HTML = "text/html"
    # A response a shared cache may store and serve to anyone. One visitor's
    # cookie on it would be every visitor's.
    SHARED_CACHE = /\b(?:public|s-maxage)\b/i

    @mutex = Mutex.new
    @wakeup = ConditionVariable.new
    @sessions = {}
    @dropped = 0
    @thread = nil
    @pid = nil
    @stopping = false

    module_function

    # Session keys dropped because the process was already tracking MAX_KEYS.
    def dropped
      @dropped
    end

    # Records one finished request against its session. A request that is
    # neither authenticated nor carrying a session id is not a session, and
    # returns here having touched nothing.
    def touch(exe, env, status)
      key = key_for(exe, env) or return nil
      exe.session_key = key
      now = Clock.now
      @mutex.synchronize do
        entry = @sessions[key] ||= begin
          drop_oldest if @sessions.size >= MAX_KEYS
          { started_at: now, last_seen_at: now, requests: 0, errors: 0, crashed: false, user: exe.user_id }
        end
        entry[:last_seen_at] = now
        entry[:requests] += 1
        entry[:errors] += 1 if status.to_i >= 500 || exe.counters[:exceptions].positive?
        entry[:crashed] = true if exe.session_crashed
        entry[:user] ||= exe.user_id
      end
    end

    # Ships one record per tracked session. Keys idle for longer than
    # config.session_timeout ship with `ended` and are dropped; the rest stay
    # and are shipped again next interval, so a long session is one row per
    # interval that the platform dedupes by id.
    def flush
      now = Clock.now
      timeout = Railwatch.config.session_timeout
      due = @mutex.synchronize do
        rows = @sessions.map { |key, entry| [ key, entry, now - entry[:last_seen_at] > timeout ] }
        rows.each { |key, _entry, ended| @sessions.delete(key) if ended }
        rows
      end
      due.each { |key, entry, ended| emit(key, entry, ended) }
    end

    # The browser client's id when the request carries one -- so the two
    # halves of the same session share a key -- else the resolved user. A
    # first page load the middleware minted an id for keys on that id, but
    # only where it would have keyed on the user: an anonymous request with
    # no cookie (a crawler, curl) opened no session before and opens none
    # now. Its browser, if it runs the client, opens it with the first beat.
    def key_for(exe, env)
      id = sent_id(env)
      return id[0, KEY_LIMIT] unless id.nil? || id.empty?

      user = exe.user_id
      return nil unless user
      env[MINTED] || "user:#{user}"[0, KEY_LIMIT]
    end

    # The browser session and tab a request came from, for the request
    # record: only what the browser client sent, never the user fallback
    # above, which names a person rather than a session.
    def browser_fields(env)
      session = browser_id(sent_id(env) || env[MINTED])
      tab = browser_id(env["HTTP_X_RAILWATCH_TAB"])
      { session_id: session, tab_id: tab }.compact
    end

    def sent_id(env)
      env["HTTP_X_RAILWATCH_SESSION"] || COOKIE.match(env["HTTP_COOKIE"])&.[](1)
    end

    # A browser's first page load carries no session cookie: the client sets
    # it once the page runs, after this request is over. Without one the
    # request would key on the user, a session no browser ever beats, and
    # the journey would start a page late. So a page the client will run on
    # -- a successful GET of an HTML document, not an Inertia visit, from an
    # app with the client installed -- that arrives with no id gets one here,
    # in the cookie the client reads and adopts. Never on a response a
    # shared cache may keep (Cache-Control public or s-maxage).
    def mint(env, status, headers)
      return unless Railwatch.config.browser_client?
      return unless env["REQUEST_METHOD"] == "GET" && status.to_i == 200
      return if env["HTTP_X_INERTIA"] || sent_id(env)
      return unless headers[Rack::CONTENT_TYPE].to_s.start_with?(HTML)
      return if SHARED_CACHE.match?(headers[Rack::CACHE_CONTROL].to_s)

      id = env[MINTED] = SecureRandom.hex(8)
      # Secure over HTTPS (behind a TLS proxy too: ssl? reads
      # X-Forwarded-Proto), so the id never rides a plain-HTTP request.
      Rack::Utils.set_cookie_header!(headers, "railwatch_session",
        { value: id, path: "/", max_age: COOKIE_MAX_AGE, same_site: :lax, secure: Rack::Request.new(env).ssl? })
    rescue StandardError => e
      # A frozen header hash: the client mints the id once the page runs.
      env.delete(MINTED)
      Railwatch.debug { "session cookie skipped: #{e.class}: #{e.message}" }
    end

    def browser_id(value)
      value if value.is_a?(String) && BROWSER_ID.match?(value)
    end

    def emit(key, entry, ended)
      Railwatch.record(:session, group: Record.group_hash(key),
        id: key, source: "server", status: status_of(entry),
        started_at: entry[:started_at], duration: ((entry[:last_seen_at] - entry[:started_at]) * 1_000_000).round,
        requests: entry[:requests], errors: entry[:errors], ended: ended, user: entry[:user])
    rescue StandardError => e
      Railwatch.debug { "session flush failed: #{e.class}: #{e.message}" }
      nil
    end

    def status_of(entry)
      return "crashed" if entry[:crashed]
      entry[:errors].positive? ? "errored" : "ok"
    end

    def drop_oldest
      @sessions.shift
      @dropped += 1
    end

    # --- background thread (mirrors Railwatch::Health) ------------------------

    def start!
      return unless Railwatch.enabled? && Railwatch.config.track_sessions
      return if defined?(Rails) && Rails.env.test?
      return unless ROLES.include?(Subscribers::ProcessInfo.role)
      return if @thread&.alive? && @pid == Process.pid

      @mutex.synchronize do
        return if @thread&.alive? && @pid == Process.pid

        @pid = Process.pid
        @stopping = false
        @thread = Thread.new { run }
        @thread.name = "railwatch-sessions"
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    # A forked child inherits a dead thread, the parent's pid, and the
    # parent's half-finished session map; both are replaced here.
    def restart_after_fork!
      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @pid = nil
      @stopping = false
      @sessions = {}
      @dropped = 0
      start!
    end

    def stop!
      return unless @thread

      @stopping = true
      @mutex.synchronize { @wakeup.signal }
      @thread.join(1)
      @thread = nil
      # Shutting down without this would throw away every session opened
      # since the last interval, on every deploy.
      flush
    end

    def run
      until @stopping
        @mutex.synchronize { @wakeup.wait(@mutex, Railwatch.config.session_flush_interval) unless @stopping }
        flush unless @stopping
      end
    end
  end
end
