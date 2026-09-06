# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"

RSpec.describe "nightrail rake tasks" do
  # spec_helper loads the app's tasks once for the whole suite; a second
  # load_tasks would append every task's action a second time.

  # Rake runs a task once per process; a second `invoke` is a silent no-op.
  # Re-enabled BEFORE each example as well as after, because the install
  # generator's own specs invoke nightrail:doctor in-process and, depending on
  # seed order, can run first -- leaving the task already-invoked and the
  # first doctor example here capturing nothing at all.
  TASKS = %w[nightrail:status nightrail:deploy nightrail:doctor nightrail:token nightrail:mcp].freeze

  before { TASKS.each { |name| Rake::Task[name].reenable } }
  after { TASKS.each { |name| Rake::Task[name].reenable } }

  def capture_task(name, *args)
    out = StringIO.new
    original = $stdout
    $stdout = out
    Rake::Task[name].invoke(*args)
    out.string
  ensure
    $stdout = original
  end

  describe "nightrail:status" do
    it "aborts when no token is configured" do
      old_token = Nightrail.config.token
      Nightrail.config.token = nil

      expect { Rake::Task["nightrail:status"].invoke }.to raise_error(SystemExit)
    ensure
      Nightrail.config.token = old_token
    end

    it "aborts when the ingest host is unreachable" do
      stub_request(:get, "http://nightrail.test/ingest/ping").to_return(status: 500, body: "err")

      expect { Rake::Task["nightrail:status"].invoke }.to raise_error(SystemExit)
    end

    it "pings the configured ingest host and prints the deploy and server when reachable" do
      stub_request(:get, "http://nightrail.test/ingest/ping").to_return(status: 200, body: "ok")

      expect { Rake::Task["nightrail:status"].invoke }.not_to raise_error
      expect(WebMock).to have_requested(:get, "http://nightrail.test/ingest/ping").at_least_once
    end

    it "invokes its ping exactly once per rake invocation" do
      stub_request(:get, "http://nightrail.test/ingest/ping").to_return(status: 200, body: "ok")

      Rake::Task["nightrail:status"].invoke

      expect(WebMock).to have_requested(:get, "http://nightrail.test/ingest/ping").times(1)
    end
  end

  describe "nightrail:deploy" do
    # Shelling out to git would make these depend on the checkout they run in.
    before { allow(Nightrail::DeployMetadata).to receive(:commits).and_return([]) }

    it "aborts when no deploy identifier is configured" do
      old_deploy = Nightrail.config.deploy
      Nightrail.config.deploy = nil

      expect { Rake::Task["nightrail:deploy"].invoke }.to raise_error(SystemExit)
    ensure
      Nightrail.config.deploy = old_deploy
    end

    it "posts the deploy, ref, name, url, and server with a bearer token" do
      stub_request(:post, "http://nightrail.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["nightrail:deploy"].invoke("myref", "myname", "myurl")

      expect(WebMock).to have_requested(:post, "http://nightrail.test/ingest/deploys").with { |req|
        body = JSON.parse(req.body)
        expect(body).to include(
          "deploy" => "abc123",
          "ref" => "myref",
          "name" => "myname",
          "url" => "myurl",
          "server" => Nightrail.config.server
        )
        expect(req.headers["Authorization"]).to eq("Bearer test-token")
        true
      }.at_least_once
    end

    it "posts the deploy payload exactly once per rake invocation" do
      stub_request(:post, "http://nightrail.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["nightrail:deploy"].invoke("myref", "myname", "myurl")

      expect(WebMock).to have_requested(:post, "http://nightrail.test/ingest/deploys").times(1)
    end

    it "posts the commit list so the platform can show a deploy diff" do
      commits = [ { sha: "aaa", author: "Cole", message: "Ship it", at: "2026-09-03T10:00:00+00:00" } ]
      allow(Nightrail::DeployMetadata).to receive(:commits).and_return(commits)
      stub_request(:post, "http://nightrail.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["nightrail:deploy"].invoke("myref")

      expect(WebMock).to have_requested(:post, "http://nightrail.test/ingest/deploys").with { |req|
        expect(JSON.parse(req.body)["commits"]).to eq(
          [ { "sha" => "aaa", "author" => "Cole", "message" => "Ship it", "at" => "2026-09-03T10:00:00+00:00" } ]
        )
        true
      }
    end

    it "posts the Kamal performer, destination, and service from the environment" do
      stub_request(:post, "http://nightrail.test/ingest/deploys").to_return(status: 200, body: "ok")
      ENV["KAMAL_PERFORMER"] = "cole"
      ENV["KAMAL_DESTINATION"] = "staging"
      ENV["KAMAL_SERVICE"] = "dummy"

      Rake::Task["nightrail:deploy"].invoke("myref")

      expect(WebMock).to have_requested(:post, "http://nightrail.test/ingest/deploys").with { |req|
        expect(JSON.parse(req.body)).to include(
          "performer" => "cole", "destination" => "staging", "service" => "dummy"
        )
        true
      }
    ensure
      ENV.delete("KAMAL_PERFORMER")
      ENV.delete("KAMAL_DESTINATION")
      ENV.delete("KAMAL_SERVICE")
    end

    it "leaves the Kamal fields null outside a Kamal deploy" do
      stub_request(:post, "http://nightrail.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["nightrail:deploy"].invoke("myref")

      expect(WebMock).to have_requested(:post, "http://nightrail.test/ingest/deploys").with { |req|
        expect(JSON.parse(req.body)).to include("performer" => nil, "destination" => nil, "service" => nil)
        true
      }
    end
  end

  # Named, not referenced: the constant is defined by the rake file, which
  # before(:all) loads long after this file is parsed.
  describe "Nightrail::DeployMetadata" do
    subject(:metadata) { Nightrail::DeployMetadata }

    it "parses git log's unit-separated output newest first" do
      allow(metadata).to receive(:git_log).and_return(
        "aaa\x1fCole\x1fShip it\x1f2026-09-03T10:00:00+00:00\n" \
        "bbb\x1fDHH\x1fEarlier\x1f2026-09-02T09:00:00+00:00\n"
      )

      expect(metadata.commits).to eq([
        { sha: "aaa", author: "Cole", message: "Ship it", at: "2026-09-03T10:00:00+00:00" },
        { sha: "bbb", author: "DHH", message: "Earlier", at: "2026-09-02T09:00:00+00:00" }
      ])
    end

    it "skips blank lines rather than emitting commits with no sha" do
      allow(metadata).to receive(:git_log).and_return("\naaa\x1fCole\x1fShip it\x1f2026-09-03T10:00:00+00:00\n\n")

      expect(metadata.commits.map { |c| c[:sha] }).to eq([ "aaa" ])
    end

    it "returns no commits inside an app container, which has no git history" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(metadata.commits).to eq([]) }
      end
    end

    it "asks git for at most 50 commits" do
      expect(metadata::MAX_COMMITS).to eq(50)
    end
  end

  describe "nightrail:doctor" do
    # Captures the checklist rather than letting eleven lines per example
    # scroll past, and reports whether the task aborted.
    def run_doctor
      out = StringIO.new
      original_out, original_err = $stdout, $stderr
      $stdout = out
      $stderr = StringIO.new
      aborted = false
      begin
        Rake::Task["nightrail:doctor"].invoke
      rescue SystemExit
        aborted = true
      end
      [ out.string, aborted ]
    ensure
      $stdout, $stderr = original_out, original_err
    end

    before { stub_request(:get, "http://nightrail.test/ingest/ping").to_return(status: 200, body: "ok") }

    it "aborts and names tracked plaintext token files without printing the token" do
      allow(Nightrail::SecretSafety).to receive(:tracked_plaintext_token_files)
        .and_return([ ".env.production", "config/initializers/nightrail.rb" ])

      output, aborted = run_doctor

      expect(aborted).to be(true)
      expect(output).to include("✗ token storage: plaintext token found in tracked file(s): " \
                                ".env.production, config/initializers/nightrail.rb")
      expect(output).not_to include(Nightrail.config.token)
    end

    it "passes every fatal check and does not abort on a healthy install" do
      output, aborted = run_doctor

      expect(aborted).to be(false)
      expect(output).to include("✓ token: test-t... (10 chars)")
      expect(output).to include("✓ token storage: no tracked plaintext Nightrail token found")
      expect(output).to include("✓ ingest url: http://nightrail.test")
      expect(output).to include("✓ ingest reachable: GET http://nightrail.test/ingest/ping")
      expect(output).to include("Nightrail is wired up.")
    end

    it "confirms the request middleware is installed, and where in the stack" do
      output, = run_doctor

      expect(output).to match(/✓ request middleware: Nightrail::Middleware::Request at position \d+/)
    end

    it "confirms the engine is mounted and the beacon route resolves" do
      output, = run_doctor

      expect(output).to include("✓ engine mounted: POST /nightrail/beacon -> nightrail/beacon#create")
    end

    it "reports the deploy and which environment variable it came from" do
      output, = run_doctor

      expect(output).to include("✓ deploy: abc123 (from NIGHTRAIL_DEPLOY)")
    end

    it "reports a deploy detected from the checkout" do
      allow(Nightrail.config).to receive(:deploy_source).and_return("REVISION")

      output, = run_doctor

      expect(output).to include("✓ deploy: abc123 (from REVISION)")
    end

    it "reports the sample rates and the ignored record types" do
      Nightrail.config.ignore = [ :view_renders ]
      output, = run_doctor

      expect(output).to include("✓ sample rates: requests=1.0")
      expect(output).to include("✓ ignored record types: view_renders")
    ensure
      Nightrail.config.ignore = []
    end

    it "reports whether a console is captured and which runner paths count as scratch" do
      output, = run_doctor

      expect(output).to include("✓ interactive sessions: console=quiet runner scratch paths=/tmp/ /var/tmp/")
    end

    it "names the profiler backend the app has installed" do
      output, = run_doctor

      expect(output).to match(/✓ profiler backend: (vernier|stackprof)/)
    end

    it "reports a missing profiler backend as a hint, not a failure" do
      allow(Nightrail::Profiler).to receive(:backend).and_return(nil)

      output, aborted = run_doctor

      expect(output).to include(%(✗ profiler backend: none -- add `gem "vernier"`))
      expect(aborted).to be(false)
    end

    it "names the entrypoint that calls startNightrail()" do
      write_app_file("app/frontend/entrypoints/inertia.tsx", %(import "x"\nstartNightrail()\n))

      output, = run_doctor

      expect(output).to include("✓ browser client imported: app/frontend/entrypoints/inertia.tsx")
    ensure
      cleanup_app_files
    end

    it "reports an entrypoint that never calls startNightrail()" do
      write_app_file("app/frontend/entrypoints/inertia.tsx", %(import "x"\ncreateInertiaApp({})\n))

      output, aborted = run_doctor

      expect(output).to include("✗ browser client imported: no entrypoint in app/frontend/entrypoints calls startNightrail()")
      expect(aborted).to be(false)
    ensure
      cleanup_app_files
    end

    it "reports optional integrations as missing without failing the check" do
      output, aborted = run_doctor

      expect(output).to include("✗ kamal post-deploy hook: not found")
      expect(output).to include("✗ browser client: not found")
      expect(output).to include("✗ test matchers: add `require \"nightrail/rspec\"`")
      expect(aborted).to be(false)
    end

    it "finds the Kamal hook, browser client, and rspec wiring when the app has them" do
      write_app_file(".kamal/hooks/post-deploy", "bin/rails nightrail:deploy\n")
      write_app_file("app/frontend/lib/nightrail.ts", "export function startNightrail() {}\n")
      write_app_file("spec/rails_helper.rb", %(require "nightrail/rspec"\n))

      output, = run_doctor

      expect(output).to include("✓ kamal post-deploy hook:")
      expect(output).to include("✓ browser client:")
      expect(output).to include(%(✓ test matchers: spec/rails_helper.rb requires "nightrail/rspec"))
    ensure
      cleanup_app_files
    end

    it "finds the minitest wiring when the app has no spec/ directory" do
      write_app_file("test/test_helper.rb", %(require "nightrail/minitest"\n))

      output, = run_doctor

      expect(output).to include(%(✓ test matchers: test/test_helper.rb requires "nightrail/minitest"))
    ensure
      cleanup_app_files
    end

    it "aborts when no token is configured" do
      old_token = Nightrail.config.token
      Nightrail.config.token = nil

      output, aborted = run_doctor

      expect(output).to include("✗ token: NIGHTRAIL_TOKEN is not set")
      expect(aborted).to be(true)
    ensure
      Nightrail.config.token = old_token
    end

    it "aborts when the ingest host is unreachable" do
      stub_request(:get, "http://nightrail.test/ingest/ping").to_return(status: 500, body: "err")

      output, aborted = run_doctor

      expect(output).to include("✗ ingest reachable:")
      expect(aborted).to be(true)
    end

    it "reports an unset deploy without aborting" do
      old_deploy = Nightrail.config.deploy
      Nightrail.config.deploy = nil

      output, aborted = run_doctor

      expect(output).to include("✗ deploy: none: set NIGHTRAIL_DEPLOY")
      expect(aborted).to be(false)
    ensure
      Nightrail.config.deploy = old_deploy
    end
  end

  describe "nightrail:token" do
    it "points at the platform this gem already ships to, not the hosted default" do
      output = capture_task("nightrail:token")

      expect(output).to include("Nightrail platform: http://nightrail.test")
      expect(output).to include("http://nightrail.test/dashboard")
      expect(output).to include("NIGHTRAIL_TOKEN=lt_...")
    end

    it "tells a self-hosted app to set NIGHTRAIL_INGEST_URL as well" do
      output = capture_task("nightrail:token")

      expect(output).to include("NIGHTRAIL_INGEST_URL=http://nightrail.test")
    end

    it "omits NIGHTRAIL_INGEST_URL when the app ships to the hosted platform" do
      old = Nightrail.config.ingest_url
      Nightrail.config.ingest_url = "https://nightrail.rebulk.com"

      output = capture_task("nightrail:token")

      expect(output).to include("Nightrail platform: https://nightrail.rebulk.com")
      expect(output).not_to include("NIGHTRAIL_INGEST_URL")
    ensure
      Nightrail.config.ingest_url = old
    end
  end

  describe "nightrail:mcp" do
    it "prints the MCP endpoint on this app's own platform host" do
      output = capture_task("nightrail:mcp")

      expect(output).to include("Nightrail MCP server: http://nightrail.test/mcp")
      expect(output).to include("http://nightrail.test/settings/profile")
    end

    it "prints a paste-ready block for every supported client" do
      output = capture_task("nightrail:mcp")

      expect(output).to include(%(claude mcp add nightrail --transport http http://nightrail.test/mcp --header "Authorization: Bearer lnt_your_token_here"))
      expect(output).to include(%("args": ["-y", "mcp-remote", "http://nightrail.test/mcp", "--header", "Authorization: Bearer lnt_your_token_here"]))
      expect(output).to include(%("mcpServers")) # Claude Desktop + Cursor
      expect(output).to include(%("servers"))    # VS Code
      expect(output).to include(%("context_servers")) # Zed
      expect(output).to include(%("method":"tools/list"))
    end
  end

  # Doctor inspects paths under Rails.root, which is the dummy app. These are
  # the only directories these examples add there, none of which the dummy app
  # ships with, so each is removed whole afterwards.
  TEMP_APP_DIRS = %w[.kamal app/frontend spec test].freeze

  def write_app_file(relative, contents)
    path = Rails.root.join(relative)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, contents)
  end

  def cleanup_app_files
    TEMP_APP_DIRS.each { |dir| FileUtils.rm_rf(Rails.root.join(dir)) }
  end
end
