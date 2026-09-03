# frozen_string_literal: true

module Lantern
  # Server-side sessions, the fallback half of release health. Every request
  # that resolves a user or carries the browser client's session id updates
  # one in-memory entry per session key; a background thread ships each entry
  # as a `session` record every config.session_flush_interval and retires the
  # ones idle for longer than config.session_timeout.
  #
  # Same thread shape as Lantern::Health -- one thread per process, parked on
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
    # The cookie the browser client sets (lantern.ts), so every request from
    # a tab carries the id its beacons already use.
    COOKIE = /(?:\A|;\s*)lantern_session=([^;]+)/
    KEY_LIMIT = 64

    @mutex = Mutex.new
    @wakeup = ConditionVariable.new
    @sessions = {}
    @dropped = 0
    @thread = nil
    @pid = nil
    @stopping = false

    # See Lantern::Health::ForkHook.
    module ForkHook
      def _fork
        pid = super
        Sessions.restart_after_fork! if pid.zero?
        pid
      end
    end

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
      timeout = Lantern.config.session_timeout
      due = @mutex.synchronize do
        rows = @sessions.map { |key, entry| [ key, entry, now - entry[:last_seen_at] > timeout ] }
        rows.each { |key, _entry, ended| @sessions.delete(key) if ended }
        rows
      end
      due.each { |key, entry, ended| emit(key, entry, ended) }
    end

    # The browser client's id when the request carries one -- so the two
    # halves of the same session share a key -- else the resolved user.
    def key_for(exe, env)
      id = env["HTTP_X_LANTERN_SESSION"] || COOKIE.match(env["HTTP_COOKIE"])&.[](1)
      return id[0, KEY_LIMIT] unless id.nil? || id.empty?

      user = exe.user_id
      user && "user:#{user}"[0, KEY_LIMIT]
    end

    def emit(key, entry, ended)
      Lantern.record(:session, group: Record.group_hash(key),
        id: key, source: "server", status: status_of(entry),
        started_at: entry[:started_at], duration: ((entry[:last_seen_at] - entry[:started_at]) * 1_000_000).round,
        requests: entry[:requests], errors: entry[:errors], ended: ended, user: entry[:user])
    rescue StandardError => e
      Lantern.debug { "session flush failed: #{e.class}: #{e.message}" }
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

    # --- background thread (mirrors Lantern::Health) ------------------------

    def start!
      return unless Lantern.enabled? && Lantern.config.track_sessions
      return if defined?(Rails) && Rails.env.test?
      return unless ROLES.include?(Subscribers::ProcessInfo.role)
      return if @thread&.alive? && @pid == Process.pid

      @mutex.synchronize do
        return if @thread&.alive? && @pid == Process.pid

        @pid = Process.pid
        @stopping = false
        @thread = Thread.new { run }
        @thread.name = "lantern-sessions"
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    # A forked child inherits a dead thread, the parent's pid, and the
    # parent's half-finished session map; both are replaced here.
    def restart_after_fork!
      @thread = nil
      @sessions = {}
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
        @mutex.synchronize { @wakeup.wait(@mutex, Lantern.config.session_flush_interval) unless @stopping }
        flush unless @stopping
      end
    end
  end
end
