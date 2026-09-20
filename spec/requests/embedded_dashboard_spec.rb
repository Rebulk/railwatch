# frozen_string_literal: true

require "spec_helper"

# The engine's in-app dashboard: telemetry written straight into the
# railwatch_telemetry database by Transport::Local, read back by the same
# controllers the hosted platform runs, rendered through the vendored
# Inertia bundle. Needs the dummy app's railwatch and railwatch_telemetry
# databases (spec/dummy/config/database.yml) with both schemas loaded.
RSpec.describe "embedded dashboard", type: :request do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  def inertia_headers = { "X-Inertia" => "true", "X-Inertia-Version" => Railwatch::AssetsHelper.digest }

  def local_write!(records, batch_id: SecureRandom.uuid)
    result = Railwatch::Transport::Local.new(Railwatch.config).deliver(records, batch_id: batch_id)
    expect(result.ok).to be(true), result.error.to_s
    result
  end

  def telemetry(&) = Railwatch::Environment.current.with_telemetry(&)

  it "writes a batch exactly once when the reporter replays it with the same id" do
    get "/widgets"
    records = railwatch_records
    id = SecureRandom.uuid

    first = local_write!(records, batch_id: id)
    replay = local_write!(records, batch_id: id)

    expect(first.accepted).to eq(replay.accepted)
    expect(telemetry { Railwatch::Telemetry::IngestBatch.where(batch_id: id).count }).to eq(1)
    expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
  end

  it "asks the reporter to retry a batch whose write failed, and counts a malformed record as rejected rather than failing" do
    get "/widgets"
    records = railwatch_records
    allow(Railwatch::Ingest::Writer).to receive(:new).and_raise(ActiveRecord::StatementInvalid, "database is locked")
    locked = Railwatch::Transport::Local.new(Railwatch.config).deliver(records, batch_id: SecureRandom.uuid)
    expect(locked.ok).to be(false)
    expect(locked.retryable?).to be(true)
    # The failure stays Railwatch's: the executor must not have reported it
    # to Rails.error, where Railwatch would capture it as an app exception
    # and open an issue about itself (seen on the first boot of a dogfood
    # host, before the telemetry database was migrated).
    expect(railwatch_records(:exception)).to be_empty

    allow(Railwatch::Ingest::Writer).to receive(:new).and_call_original
    mixed = Railwatch::Transport::Local.new(Railwatch.config).deliver(records + [ "not a record" ], batch_id: SecureRandom.uuid)
    expect(mixed.ok).to be(true)
    expect(mixed.rejected).to eq(1)
    expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
  end

  it "leaves a batch's exception grouping on its ledger row when grouping fails, for the maintenance clock to finish" do
    get "/boom"
    records = railwatch_records
    allow(Railwatch::GroupExceptionsJob).to receive(:new).and_raise(RuntimeError, "meta db unavailable")

    local_write!(records)

    pending = telemetry { Railwatch::Telemetry::IngestBatch.with_pending_followups.to_a }
    expect(pending.size).to eq(1)
    expect(pending.first.followups["group_exception_ids"]).to be_present
    expect(Railwatch::Issue.count).to eq(0)

    allow(Railwatch::GroupExceptionsJob).to receive(:new).and_call_original
    Railwatch::Maintenance.tick
    expect(Railwatch::Issue.sole.title).to eq("ArgumentError: kaboom")
    expect(Railwatch::Issue.sole.occurrences).to eq(1)
    expect(telemetry { Railwatch::Telemetry::IngestBatch.with_pending_followups.count }).to eq(0)

    # And once more, as the maintenance drain would if the outbox clear had
    # not stuck: the receipt makes the second pass a no-op.
    Railwatch::Maintenance.tick(now: Time.current + 2.minutes)
    expect(Railwatch::Issue.sole.occurrences).to eq(1)
  end

  it "writes a request record into the telemetry database and shows it on the requests page" do
    get "/widgets"
    records = railwatch_records
    expect(records.map { |r| r[:t] }).to include("request")

    local_write!(records)

    stored = Railwatch::Environment.current.with_telemetry { Railwatch::Telemetry::Execution.where(kind: "request").last }
    expect(stored).to be_present
    expect(stored.name).to eq("GET /widgets(.:format)")

    get "/railwatch/apps/1/envs/1/requests/#{stored.execution_id}", headers: inertia_headers
    expect(response).to have_http_status(:ok)
    page = response.parsed_body
    expect(page["component"]).to eq("executions/show")
    expect(page["props"]["embedded"]).to be(true)
    expect(page["props"]["environment"]).to include("id" => 1, "name" => "test")
    expect(page["props"]["execution"]).to include("name" => "GET /widgets(.:format)", "kind" => "request")
  end

  it "groups a raised exception into an issue as the batch lands, without touching the host's job queue" do
    get "/boom"
    result = local_write!(railwatch_records)
    expect(result.rejected).to eq(0)
    expect(enqueued_jobs).to be_empty

    issue = Railwatch::Issue.sole
    expect(telemetry { Railwatch::Telemetry::IngestBatch.with_pending_followups.count }).to eq(0)
    expect(issue.key).to eq("DUMM-1")
    expect(issue.title).to eq("ArgumentError: kaboom")
    expect(issue.environment_id).to eq(1)

    get "/railwatch/issues", headers: inertia_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["props"]["issues"].map { |i| i["key"] }).to eq([ "DUMM-1" ])

    get "/railwatch/issues/#{issue.id}", headers: inertia_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["props"]["issue"]["key"]).to eq("DUMM-1")
  end

  it "serves the vendored bundle's HTML shell, assets and favicon without an asset pipeline" do
    get "/railwatch"
    expect(response).to redirect_to("/railwatch/apps/1/envs/1")

    get "/railwatch/apps/1/envs/1"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<meta name="railwatch-mount" content="/railwatch">')
    expect(response.body).to include('data-page=')
    script = response.body[%r{/railwatch/assets/assets/[^"']+\.js}]
    expect(script).to be_present

    get script
    expect(response).to have_http_status(:ok)
    expect(response.headers["cache-control"]).to include("immutable")

    get "/railwatch/icon.svg"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/svg+xml")
  end

  it "names the operator from the host's dashboard_user resolver" do
    Railwatch.config.dashboard_user = ->(_request) { { id: 7, name: "Ada", email: "ada@example.com" } }

    get "/railwatch/apps/1/envs/1", headers: inertia_headers
    expect(response.parsed_body["props"]["auth"]["user"]).to include("name" => "Ada", "email" => "ada@example.com")
  ensure
    Railwatch.config.dashboard_user = nil
  end

  # An app that serves static files from nginx, a CDN or Thruster sets
  # public_file_server.enabled = false, and then ActionDispatch::Static is not
  # in the stack at all. Inserting relative to a middleware that is not there
  # raises, which would take the host application down at boot rather than
  # merely losing the dashboard's assets.
  it "mounts its asset middleware whether or not the host serves static files itself" do
    stack = Rails.application.middleware
    expect(stack.map(&:klass)).to include(Railwatch::DashboardAssets)

    stack_class = Class.new do
      def initialize = @operations = []
      attr_reader :operations
      def insert_before(*args, **kwargs) = @operations << [ :insert_before, args, kwargs ]
      def insert(*args, **kwargs) = @operations << [ :insert, args, kwargs ]
    end
    app_with = double(config: double(public_file_server: double(enabled: true)), middleware: stack_class.new)
    app_without = double(config: double(public_file_server: double(enabled: false)), middleware: stack_class.new)

    expect { Railwatch::DashboardAssets.install!(app_with, root: "/tmp/rw") }.not_to raise_error
    expect { Railwatch::DashboardAssets.install!(app_without, root: "/tmp/rw") }.not_to raise_error

    expect(app_with.middleware.operations.first[0]).to eq(:insert_before)
    expect(app_with.middleware.operations.first[1]).to eq([ ActionDispatch::Static, Railwatch::DashboardAssets ])
    # No ActionDispatch::Static to anchor to: the front of the stack instead.
    expect(app_without.middleware.operations.first[0]).to eq(:insert)
    expect(app_without.middleware.operations.first[1]).to eq([ 0, Railwatch::DashboardAssets ])
    expect(app_without.middleware.operations.first[2]).to eq({ root: "/tmp/rw" })
  end

  describe "HTTP Basic authentication (Mission Control Jobs' shape)" do
    def basic(user, password) = { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user, password) }

    # A `before`, not `around`: spec_helper's global before turns Basic off
    # for every other example and runs inside an around, so it would undo
    # this. Per-example config is rebuilt by the suite, so no restore.
    before do
      Railwatch.config.http_basic_auth_enabled = true
      Railwatch.config.http_basic_auth_user = nil
      Railwatch.config.http_basic_auth_password = nil
    end

    it "is closed, not open, when Basic is on and no credentials are configured" do
      get "/railwatch/apps/1/envs/1", headers: inertia_headers
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include("railwatch:authentication:configure")
    end

    it "challenges for and accepts the configured credentials" do
      Railwatch.config.http_basic_auth_user = "ops"
      Railwatch.config.http_basic_auth_password = "s3cret"

      get "/railwatch/apps/1/envs/1", headers: inertia_headers
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include("Basic")

      get "/railwatch/apps/1/envs/1", headers: inertia_headers.merge(basic("ops", "wrong"))
      expect(response).to have_http_status(:unauthorized)

      get "/railwatch/apps/1/envs/1", headers: inertia_headers.merge(basic("ops", "s3cret"))
      expect(response).to have_http_status(:ok)
    end

    it "stands aside when the host turns Basic off to use its own base controller or routes constraint" do
      Railwatch.config.http_basic_auth_enabled = false
      get "/railwatch/apps/1/envs/1", headers: inertia_headers
      expect(response).to have_http_status(:ok)
    end

    it "names the gate in force, so the doctor and the boot warning can say which it is" do
      config = Railwatch.config
      expect(config.dashboard_gate).to eq(:basic)

      config.http_basic_auth_enabled = false
      expect(config.dashboard_gate).to eq(:undeclared)

      config.dashboard_open = true
      expect(config.dashboard_gate).to eq(:open)

      config.dashboard_user = ->(_request) { { id: 1, name: "Ada" } }
      expect(config.dashboard_gate).to eq(:resolver)

      config.base_controller_class = "ActionController::API"
      expect(config.dashboard_gate).to eq(:controller)
    ensure
      config.dashboard_open = false
      config.dashboard_user = nil
      config.base_controller_class = Railwatch::Configuration::DEFAULT_BASE_CONTROLLER
    end

    # Action Cable runs on the host's own /cable endpoint, which a routes
    # constraint around the engine's mount does not cover, so an undeclared
    # gate has to refuse rather than assume something is in front of it.
    it "lets the declared gate decide a live-update subscription" do
      config = Railwatch.config
      request = ->(headers = {}) { ActionDispatch::Request.new(Rack::MockRequest.env_for("/cable", headers)) }
      creds = { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("ops", "s3cret") }

      config.http_basic_auth_user = "ops"
      config.http_basic_auth_password = "s3cret"
      expect(config.dashboard_channel_allowed?(request.call)).to be(false)
      expect(config.dashboard_channel_allowed?(request.call(creds))).to be(true)

      config.http_basic_auth_enabled = false
      expect(config.dashboard_channel_allowed?(request.call)).to be(false)

      config.dashboard_open = true
      expect(config.dashboard_channel_allowed?(request.call)).to be(true)

      config.dashboard_open = false
      config.base_controller_class = "AdminController"
      expect(config.dashboard_channel_allowed?(request.call)).to be(false)
      config.dashboard_user = ->(_req) { false }
      expect(config.dashboard_channel_allowed?(request.call)).to be(false)
      config.dashboard_user = ->(req) { req.headers["X-Operator"] && { id: 1, name: "Ada" } }
      expect(config.dashboard_channel_allowed?(request.call)).to be(false)
      expect(config.dashboard_channel_allowed?(request.call("HTTP_X_OPERATOR" => "1"))).to be(true)
    ensure
      config.dashboard_open = false
      config.dashboard_user = nil
      config.base_controller_class = Railwatch::Configuration::DEFAULT_BASE_CONTROLLER
    end

    it "does not gate the beacon, which is the app's own browser client posting timings" do
      post "/railwatch/beacon", params: { visits: [] }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).not_to have_http_status(:unauthorized)
    end

    it "applies the same rule to the live channel" do
      Railwatch.config.http_basic_auth_user = "ops"
      Railwatch.config.http_basic_auth_password = "s3cret"
      request = ->(headers) { ActionDispatch::Request.new(Rack::MockRequest.env_for("/cable", headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })) }

      expect(Railwatch.config.http_basic_auth_ok?(request.call({}))).to be(false)
      expect(Railwatch.config.http_basic_auth_ok?(request.call(basic("ops", "s3cret")))).to be(true)
    end
  end

  it "refuses a stale bundle version with the Inertia 409 so the browser reloads" do
    get "/railwatch/apps/1/envs/1", headers: inertia_headers.merge("X-Inertia-Version" => "stale")
    expect(response).to have_http_status(:conflict)
    expect(response.headers["X-Inertia-Location"]).to end_with("/railwatch/apps/1/envs/1")
  end
end
