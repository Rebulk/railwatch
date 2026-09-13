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

    req = railwatch_records(:request).sole
    expect(req).to include(method: "GET", route: "/widgets(.:format)", controller: "widgets", action: "index", status_code: 200)
    expect(req[:stages].keys).to include("middleware_before", "action")
    expect(req[:counters][:queries]).to be >= 4
    expect(req[:counters][:logs]).to eq(1)
    expect(req[:user]).to eq("1")
    expect(req[:duration]).to be > 0
    expect(req[:headers]).to have_key("Host")

    queries = railwatch_records(:query)
    expect(queries.map { |q| q[:execution_id] }.uniq).to eq([ req[:execution_id] ])
    expect(queries.map { |q| q[:trace_id] }.uniq).to eq([ req[:trace_id] ])
    expect(queries.first[:sql]).to include("SELECT")
    expect(queries.first[:adapter]).to eq("sqlite")
  end

  it "flags an N+1 when the same query shape repeats past the threshold" do
    Railwatch.config.n_plus_one_threshold = 3
    get "/widgets"
    n1 = railwatch_records(:n_plus_one).sole
    expect(n1[:sql]).to include("gadgets")
    expect(n1[:count]).to eq(3)
  ensure
    Railwatch.config.n_plus_one_threshold = 5
  end

  # activerecord-tenanted's TenantSelector (and any around_action) binds the
  # tenant INSIDE the controller stack, after Railwatch's Rack middleware has
  # already opened the execution. rebulk-system's first production hour
  # shipped 2,900 requests with no tenant on any of them because of this.
  it "stamps the tenant bound during the request onto the request record and its children" do
    tenant_record = Class.new do
      class << self
        attr_accessor :current_tenant
      end
    end
    stub_const("TenantRecord", tenant_record)
    allow_any_instance_of(WidgetsController).to receive(:index).and_wrap_original do |m, *args|
      TenantRecord.current_tenant = "acme"
      m.call(*args)
    ensure
      TenantRecord.current_tenant = nil
    end

    get "/widgets"

    expect(railwatch_records(:request).sole[:tenant]).to eq("acme")
    before_bind, after_bind = railwatch_records(:query).partition { |q| q[:sql].include?("users") }
    # The dummy app's before_action loads the user before the tenant is bound.
    expect(before_bind.map { |q| q[:tenant] }).to eq([ nil ])
    expect(after_bind.size).to be >= 2
    expect(after_bind).to all(include(tenant: "acme"))
  end

  it "captures an unhandled exception with frames and marks the request 500" do
    get "/boom"
    expect(response).to have_http_status(:internal_server_error)

    ex = railwatch_records(:exception).sole
    expect(ex).to include(class: "ArgumentError", message: "kaboom", handled: false)
    expect(ex[:frames].first[:in_app]).to be true
    expect(ex[:frames].first[:file]).to eq("app/controllers/widgets_controller.rb")
    expect(ex[:frames].first[:code]).to be_a(Hash)

    req = railwatch_records(:request).sole
    expect(req[:status_code]).to eq(500)
    expect(req[:counters][:exceptions]).to eq(1)
    expect(req[:exception_preview]).to eq("ArgumentError: kaboom")
  end

  it "captures handled errors reported through Rails.error with their context" do
    get "/handled"
    ex = railwatch_records(:exception).sole
    expect(ex).to include(handled: true, severity: "warning", message: "swallowed")
    expect(JSON.parse(ex[:context])).to include("section" => "handled")
  end

  it "records cache hits and misses and drops vendor keys" do
    get "/cached"
    events = railwatch_records(:cache_event)
    expect(events.map { |e| e[:type] }).to eq(%w[generate write hit])
    expect(events.map { |e| e[:key] }.uniq).to eq([ "widgets/count" ])
  end

  it "records outgoing HTTP with the query string stripped" do
    get "/outbound"
    out = railwatch_records(:outgoing_request).sole
    expect(out).to include(host: "example.test", method: "GET", url: "http://example.test/api/v1/things", status_code: 200)
    expect(out[:duration]).to be >= 0
  end

  it "records mail deliveries" do
    get "/mail"
    mail = railwatch_records(:mail).sole
    expect(mail).to include(mailer: "WidgetMailer", subject: "Widget ready", to: 1, failed: false)
  end

  it "records enqueued jobs and links the attempt back to the request trace" do
    get "/enqueue"
    enq = railwatch_records(:enqueued_job).sole
    req = railwatch_records(:request).sole
    expect(enq).to include(name: "WidgetJob", queue: "default", trace_id: req[:trace_id])

    perform_enqueued_jobs
    attempt = railwatch_records(:job_attempt).sole
    expect(attempt).to include(name: "WidgetJob", status: "processed", trace_id: req[:trace_id])
    expect(attempt[:execution_source]).to eq("job")
    expect(attempt[:counters][:queries]).to be >= 1
  end

  it "adds Inertia fields when the response is an Inertia response" do
    get "/inertia", headers: { "X-Inertia" => "true", "X-Inertia-Version" => "v9", "X-Inertia-Partial-Data" => "a" }
    req = railwatch_records(:request).sole
    expect(req[:inertia]).to include(component: "widgets/index", version: "v9", partial_only: "a")
    expect(req[:inertia][:props_bytes]).to be > 0
  end

  it "times the Inertia SSR render for a full-page (non-XHR) visit" do
    stub_request(:post, "http://ssr.test/render")
      .to_return(status: 200, body: { head: [], body: "<div>ssr</div>" }.to_json, headers: { "Content-Type" => "application/json" })
    get "/ssr_widgets"
    expect(response.body).to include("<div>ssr</div>")
    req = railwatch_records(:request).sole
    expect(req[:inertia][:ssr_ms]).to be_a(Numeric)
    expect(req[:inertia][:ssr_ms]).to be >= 0
  end

  it "ships nothing for a route sampled out with railwatch_sample" do
    get "/sampled"
    expect(railwatch_records).to be_empty
  end

  it "records nothing inside Railwatch.ignore" do
    get "/ignored"
    expect(railwatch_records(:query).map { |q| q[:sql] }.grep(/COUNT/)).to be_empty
  end

  it "still ships an unhandled exception when the request was sampled out" do
    Railwatch.config.sample[:requests] = 0.0
    get "/boom"
    expect(railwatch_records(:exception).size).to eq(1)
    expect(railwatch_records(:request).size).to eq(1)
    expect(railwatch_records(:query)).to be_empty
  end

  it "ships nothing for an unhandled exception when both requests and exceptions are sampled out" do
    Railwatch.config.sample[:requests] = 0.0
    Railwatch.config.sample[:exceptions] = 0.0
    get "/boom"
    expect(railwatch_records).to be_empty
  ensure
    Railwatch.config.sample[:exceptions] = 1.0
  end

  it "reports the request's verb, domain, and any uploaded files" do
    file = Tempfile.new(%w[upload .txt])
    file.write("hello")
    file.rewind
    post "/upload", params: { attachment: Rack::Test::UploadedFile.new(file.path, "text/plain") }
    req = railwatch_records(:request).sole
    expect(req[:route_methods]).to eq([ "POST" ])
    expect(req[:route_domain]).to eq("www.example.com")
    expect(req[:files].size).to eq(1)
    expect(req[:files].first).to include(name: "attachment", content_type: "text/plain")
    expect(req[:files].first[:size]).to be > 0
  ensure
    file.close
    file.unlink
  end
end
