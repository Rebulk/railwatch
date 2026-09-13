# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Sessions, type: :request do
  # The map and the drop counter live for the life of the process, like the
  # health sampler's memoised Puma server, so each example starts from empty.
  before do
    described_class.instance_variable_set(:@sessions, {})
    described_class.instance_variable_set(:@dropped, 0)
  end

  let(:cookie) { { "HTTP_COOKIE" => "other=1; railwatch_session=s1" } }

  def sessions = described_class.instance_variable_get(:@sessions)

  # Flushes the map into records and returns the newest session record.
  def flushed
    described_class.flush
    railwatch_records(:session).last
  end

  it "does not open a session for a request with no user and no session id" do
    get "/widgets"

    expect(sessions).to be_empty
    expect(railwatch_records(:session)).to be_empty
  end

  it "keys the session on the browser client's cookie so both halves share an id" do
    get "/widgets", headers: cookie

    session = flushed
    expect(session).to include(t: "session", id: "s1", source: "server", status: "ok",
                               requests: 1, errors: 0, ended: false)
    expect(session[:duration]).to be_a(Integer).and be >= 0
    expect(session[:started_at]).to be_within(60.0).of(Time.now.to_f)
  end

  it "accepts the session id from an X-Railwatch-Session header" do
    get "/widgets", headers: { "X-Railwatch-Session" => "hdr1" }

    expect(flushed).to include(id: "hdr1")
  end

  it "keys the session on the resolved user when the request carries no session id" do
    allow(Railwatch::Subscribers::Users).to receive(:resolve_id).and_return("7")

    get "/widgets"

    expect(flushed).to include(id: "user:7", user: "7")
  end

  it "escalates ok to errored to crashed and never back down" do
    get "/widgets", headers: cookie
    expect(flushed).to include(status: "ok", requests: 1, errors: 0)

    get "/handled", headers: cookie
    expect(flushed).to include(status: "errored", requests: 2, errors: 1)

    get "/boom", headers: cookie
    expect(flushed).to include(status: "crashed", requests: 3)

    get "/widgets", headers: cookie
    expect(flushed).to include(status: "crashed", requests: 4)
  end

  it "ends and forgets a session idle for longer than config.session_timeout" do
    get "/widgets", headers: cookie
    Railwatch.config.session_timeout = 0.0

    expect(flushed).to include(id: "s1", ended: true)
    expect(sessions).to be_empty
  ensure
    Railwatch.config.session_timeout = 1800.0
  end

  it "keeps flushing a live session so a long one is one row per interval" do
    get "/widgets", headers: cookie

    2.times { described_class.flush }

    expect(railwatch_records(:session).map { |r| r[:id] }).to eq(%w[s1 s1])
    expect(sessions.keys).to eq(%w[s1])
  end

  it "caps the map at MAX_KEYS, dropping the oldest session and counting the drop" do
    stub_const("Railwatch::Sessions::MAX_KEYS", 2)
    exe = Railwatch::Execution.new(source: :request, sampled: true)

    %w[a b c].each { |id| described_class.touch(exe, { "HTTP_COOKIE" => "railwatch_session=#{id}" }, 200) }

    expect(sessions.keys).to eq(%w[b c])
    expect(described_class.dropped).to eq(1)
  end

  it "tracks nothing when track_sessions is off" do
    Railwatch.config.track_sessions = false

    get "/widgets", headers: cookie

    expect(sessions).to be_empty
    expect(railwatch_records(:session)).to be_empty
  ensure
    Railwatch.config.track_sessions = true
  end

  it "still aggregates but ships nothing when sessions are ignored" do
    Railwatch.config.ignore = [ :sessions ]

    get "/widgets", headers: cookie
    described_class.flush

    expect(sessions.keys).to eq(%w[s1])
    expect(railwatch_records(:session)).to be_empty
  ensure
    Railwatch.config.ignore = []
  end

  it "never raises out of a flush, even when writing the record fails" do
    get "/widgets", headers: cookie
    allow(Railwatch).to receive(:record).and_raise("boom")

    expect { described_class.flush }.not_to raise_error
  end

  describe ".start!" do
    it "does not start a thread in the test environment" do
      described_class.start!
      expect(described_class.instance_variable_get(:@thread)).to be_nil
    end

    it "does not start a thread when track_sessions is off" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(Railwatch::Subscribers::ProcessInfo).to receive(:role).and_return("web")
      Railwatch.config.track_sessions = false

      described_class.start!
      expect(described_class.instance_variable_get(:@thread)).to be_nil
    ensure
      Railwatch.config.track_sessions = true
    end

    it "does not start a thread for a worker process, which never opens a session" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(Railwatch::Subscribers::ProcessInfo).to receive(:role).and_return("worker")

      described_class.start!
      expect(described_class.instance_variable_get(:@thread)).to be_nil
    end

    it "starts exactly one thread for a web process, and stop! flushes and shuts it down" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(Railwatch::Subscribers::ProcessInfo).to receive(:role).and_return("web")
      # A long interval parks the thread on the ConditionVariable, so the only
      # flush that happens is the one stop! does on the way out.
      Railwatch.config.session_flush_interval = 30.0
      get "/widgets", headers: cookie

      described_class.start!
      thread = described_class.instance_variable_get(:@thread)
      described_class.start!

      expect(thread).to be_alive
      expect(described_class.instance_variable_get(:@thread)).to equal(thread)

      described_class.stop!
      expect(thread).not_to be_alive
      expect(railwatch_records(:session).last).to include(id: "s1")
    ensure
      described_class.stop!
      Railwatch.config.session_flush_interval = 60.0
    end
  end
end

RSpec.describe "Railwatch::Sessions fork state" do
  it "replaces inherited synchronization, session, and drop state" do
    old_mutex = Railwatch::Sessions.instance_variable_get(:@mutex)
    old_wakeup = Railwatch::Sessions.instance_variable_get(:@wakeup)
    Railwatch::Sessions.instance_variable_set(:@sessions, "parent" => {})
    Railwatch::Sessions.instance_variable_set(:@dropped, 3)

    Railwatch::Sessions.restart_after_fork!

    expect(Railwatch::Sessions.instance_variable_get(:@mutex)).not_to equal(old_mutex)
    expect(Railwatch::Sessions.instance_variable_get(:@wakeup)).not_to equal(old_wakeup)
    expect(Railwatch::Sessions.instance_variable_get(:@sessions)).to be_empty
    expect(Railwatch::Sessions.dropped).to eq(0)
    expect(Railwatch::Sessions.instance_variable_get(:@pid)).to be_nil
  end
end
