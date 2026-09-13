# frozen_string_literal: true

require "spec_helper"

RSpec.describe "session record", type: :request do
  let(:started_ms) { (Time.now.to_f - 60) * 1000 }

  def post_beacon(payload)
    post "/railwatch/beacon", params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  def visit(status: "success")
    { component: "Widgets/Index", url: "/widgets", method: "GET",
      started_at: Time.now.to_f * 1000, duration_ms: 1, status: status }
  end

  it "opens the session with status started and no duration on the flush that mints it" do
    post_beacon(visits: [], session: { id: "s1", started_at: started_ms })
    expect(response).to have_http_status(:no_content)

    session = railwatch_records(:session).sole
    expect(session).to include(v: 1, t: "session", id: "s1", source: "browser", status: "started",
                               duration: nil, visits: 0, errors: 0, ended: false)
    expect(session[:started_at]).to be_within(1.0).of(started_ms / 1000.0)
    expect(session[:deploy]).to eq("abc123")
  end

  it "beats the session along with the visits in the same flush, counting errored visits" do
    post_beacon(visits: [ visit, visit(status: "error"), visit ],
                session: { id: "s1", started_at: started_ms, duration_ms: 4200 })

    expect(railwatch_records(:session).sole).to include(source: "browser", status: "ok",
                                                      duration: 4_200_000, visits: 3, errors: 1, ended: false)
    expect(railwatch_records(:visit).size).to eq(3)
  end

  it "closes the session when the client flushes on pagehide" do
    post_beacon(visits: [ visit ], session: { id: "s1", started_at: started_ms, duration_ms: 9000, ended: true })

    expect(railwatch_records(:session).sole).to include(ended: true, status: "ok")
  end

  it "ships exactly one session record per beacon flush however many visits it carried" do
    post_beacon(visits: Array.new(5) { visit }, session: { id: "s1", started_at: started_ms, duration_ms: 1000 })

    expect(railwatch_records(:session).size).to eq(1)
  end

  it "ships no session record for a flush that carries only visits" do
    post_beacon(visits: [ visit ])

    expect(railwatch_records(:session)).to be_empty
    expect(railwatch_records(:visit).size).to eq(1)
  end

  it "ignores a session with a blank id rather than opening one" do
    post_beacon(visits: [ visit ], session: { id: "", started_at: started_ms })

    expect(railwatch_records(:session)).to be_empty
  end

  it "threads the resolved user and the current tenant onto the session" do
    allow(Railwatch::Subscribers::Users).to receive(:resolve_id).and_return("42")
    stub_const("TenantRecord", Class.new { def self.current_tenant = "acme" })
    post_beacon(visits: [], session: { id: "s1", started_at: started_ms })

    expect(railwatch_records(:session).sole).to include(user: "42", tenant: "acme")
  end

  it "ships nothing when beacon_enabled is disabled" do
    Railwatch.config.beacon_enabled = false
    post_beacon(visits: [], session: { id: "s1", started_at: started_ms })

    expect(railwatch_records(:session)).to be_empty
  ensure
    Railwatch.config.beacon_enabled = true
  end
end
