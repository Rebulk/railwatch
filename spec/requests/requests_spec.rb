# frozen_string_literal: true

require "spec_helper"

RSpec.describe "request instrumentation", type: :request do
  before do
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
    User.create!(name: "Cole", email: "cole@example.com")
  end

  it "emits one request record with route, stages, counters, user, and links its queries by execution_id" do
    get "/widgets"
    expect(response).to have_http_status(:ok)

    req = lantern_records(:request).sole
    expect(req).to include(method: "GET", route: "/widgets(.:format)", controller: "widgets", action: "index", status_code: 200)
    expect(req[:stages].keys).to include("middleware_before", "action")
    expect(req[:counters][:queries]).to be >= 4
    expect(req[:counters][:logs]).to eq(1)
    expect(req[:user]).to eq("1")
    expect(req[:duration]).to be > 0
    expect(req[:headers]).to have_key("Host")

    queries = lantern_records(:query)
    expect(queries.map { |q| q[:execution_id] }.uniq).to eq([ req[:execution_id] ])
    expect(queries.map { |q| q[:trace_id] }.uniq).to eq([ req[:trace_id] ])
    expect(queries.first[:sql]).to include("SELECT")
    expect(queries.first[:adapter]).to eq("sqlite")
  end

  it "flags an N+1 when the same query shape repeats past the threshold" do
    Lantern.config.n_plus_one_threshold = 3
    get "/widgets"
    n1 = lantern_records(:n_plus_one).sole
    expect(n1[:sql]).to include("gadgets")
    expect(n1[:count]).to eq(3)
  ensure
    Lantern.config.n_plus_one_threshold = 5
  end

  it "captures an unhandled exception with frames and marks the request 500" do
    get "/boom"
    expect(response).to have_http_status(:internal_server_error)

    ex = lantern_records(:exception).sole
    expect(ex).to include(class: "ArgumentError", message: "kaboom", handled: false)
    expect(ex[:frames].first[:in_app]).to be true
    expect(ex[:frames].first[:file]).to eq("app/controllers/widgets_controller.rb")
    expect(ex[:frames].first[:code]).to be_a(Hash)

    req = lantern_records(:request).sole
    expect(req[:status_code]).to eq(500)
    expect(req[:counters][:exceptions]).to eq(1)
    expect(req[:exception_preview]).to eq("ArgumentError: kaboom")
  end

  it "captures handled errors reported through Rails.error with their context" do
    get "/handled"
    ex = lantern_records(:exception).sole
    expect(ex).to include(handled: true, severity: "warning", message: "swallowed")
    expect(JSON.parse(ex[:context])).to include("section" => "handled")
  end

  it "records cache hits and misses and drops vendor keys" do
    get "/cached"
    events = lantern_records(:cache_event)
    expect(events.map { |e| e[:type] }).to eq(%w[generate write hit])
    expect(events.map { |e| e[:key] }.uniq).to eq([ "widgets/count" ])
  end

  it "records outgoing HTTP with the query string stripped" do
    get "/outbound"
    out = lantern_records(:outgoing_request).sole
    expect(out).to include(host: "example.test", method: "GET", url: "http://example.test/api/v1/things", status_code: 200)
    expect(out[:duration]).to be >= 0
  end

  it "records mail deliveries" do
    get "/mail"
    mail = lantern_records(:mail).sole
    expect(mail).to include(mailer: "WidgetMailer", subject: "Widget ready", to: 1, failed: false)
  end

  it "records enqueued jobs and links the attempt back to the request trace" do
    get "/enqueue"
    enq = lantern_records(:enqueued_job).sole
    req = lantern_records(:request).sole
    expect(enq).to include(name: "WidgetJob", queue: "default", trace_id: req[:trace_id])

    perform_enqueued_jobs
    attempt = lantern_records(:job_attempt).sole
    expect(attempt).to include(name: "WidgetJob", status: "processed", trace_id: req[:trace_id])
    expect(attempt[:execution_source]).to eq("job")
    expect(attempt[:counters][:queries]).to be >= 1
  end

  it "adds Inertia fields when the response is an Inertia response" do
    get "/inertia", headers: { "X-Inertia" => "true", "X-Inertia-Version" => "v9", "X-Inertia-Partial-Data" => "a" }
    req = lantern_records(:request).sole
    expect(req[:inertia]).to include(component: "widgets/index", version: "v9", partial_only: "a")
    expect(req[:inertia][:props_bytes]).to be > 0
  end

  it "ships nothing for a route sampled out with lantern_sample" do
    get "/sampled"
    expect(lantern_records).to be_empty
  end

  it "records nothing inside Lantern.ignore" do
    get "/ignored"
    expect(lantern_records(:query).map { |q| q[:sql] }.grep(/COUNT/)).to be_empty
  end

  it "still ships an unhandled exception when the request was sampled out" do
    Lantern.config.sample[:requests] = 0.0
    get "/boom"
    expect(lantern_records(:exception).size).to eq(1)
    expect(lantern_records(:request).size).to eq(1)
    expect(lantern_records(:query)).to be_empty
  end
end
