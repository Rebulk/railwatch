# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"

RSpec.describe "railwatch rake tasks" do
  # spec_helper loads the app's tasks once for the whole suite; a second
  # load_tasks would append every task's action a second time.

  # Rake runs a task once per process; a second `invoke` is a silent no-op.
  # Re-enabled BEFORE each example as well as after, because the install
  # generator's own specs invoke railwatch:doctor in-process and, depending on
  # seed order, can run first -- leaving the task already-invoked and the
  # first doctor example here capturing nothing at all.
  TASKS = %w[railwatch:status railwatch:deploy railwatch:doctor railwatch:token railwatch:mcp].freeze

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

  describe "railwatch:status" do
    it "aborts when no token is configured" do
      old_token = Railwatch.config.token
      Railwatch.config.token = nil

      expect { Rake::Task["railwatch:status"].invoke }.to raise_error(SystemExit)
    ensure
      Railwatch.config.token = old_token
    end

    it "aborts when the ingest host is unreachable" do
      stub_request(:get, "http://railwatch.test/ingest/ping").to_return(status: 500, body: "err")

      expect { Rake::Task["railwatch:status"].invoke }.to raise_error(SystemExit)
    end

    it "pings the configured ingest host and prints the deploy and server when reachable" do
      stub_request(:get, "http://railwatch.test/ingest/ping").to_return(status: 200, body: "ok")

      expect { Rake::Task["railwatch:status"].invoke }.not_to raise_error
      expect(WebMock).to have_requested(:get, "http://railwatch.test/ingest/ping").at_least_once
    end

    it "invokes its ping exactly once per rake invocation" do
      stub_request(:get, "http://railwatch.test/ingest/ping").to_return(status: 200, body: "ok")

      Rake::Task["railwatch:status"].invoke

      expect(WebMock).to have_requested(:get, "http://railwatch.test/ingest/ping").times(1)
    end
  end

  describe "railwatch:deploy" do
    # Shelling out to git would make these depend on the checkout they run in.
    before { allow(Railwatch::DeployMetadata).to receive(:commits).and_return([]) }

    it "aborts when no deploy identifier is configured" do
      old_deploy = Railwatch.config.deploy
      Railwatch.config.deploy = nil

      expect { Rake::Task["railwatch:deploy"].invoke }.to raise_error(SystemExit)
    ensure
      Railwatch.config.deploy = old_deploy
    end

    it "posts the deploy, ref, name, url, and server with a bearer token" do
      stub_request(:post, "http://railwatch.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["railwatch:deploy"].invoke("myref", "myname", "myurl")

      expect(WebMock).to have_requested(:post, "http://railwatch.test/ingest/deploys").with { |req|
        body = JSON.parse(req.body)
        expect(body).to include(
          "deploy" => "abc123",
          "ref" => "myref",
          "name" => "myname",
          "url" => "myurl",
          "server" => Railwatch.config.server
        )
        expect(req.headers["Authorization"]).to eq("Bearer test-token")
        true
      }.at_least_once
    end

    it "posts the deploy payload exactly once per rake invocation" do
      stub_request(:post, "http://railwatch.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["railwatch:deploy"].invoke("myref", "myname", "myurl")

      expect(WebMock).to have_requested(:post, "http://railwatch.test/ingest/deploys").times(1)
    end

    it "posts the commit list so the platform can show a deploy diff" do
      commits = [ { sha: "aaa", author: "Cole", message: "Ship it", at: "2026-09-03T10:00:00+00:00" } ]
      allow(Railwatch::DeployMetadata).to receive(:commits).and_return(commits)
      stub_request(:post, "http://railwatch.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["railwatch:deploy"].invoke("myref")

      expect(WebMock).to have_requested(:post, "http://railwatch.test/ingest/deploys").with { |req|
        expect(JSON.parse(req.body)["commits"]).to eq(
          [ { "sha" => "aaa", "author" => "Cole", "message" => "Ship it", "at" => "2026-09-03T10:00:00+00:00" } ]
        )
        true
      }
    end

    it "posts the Kamal performer, destination, and service from the environment" do
      stub_request(:post, "http://railwatch.test/ingest/deploys").to_return(status: 200, body: "ok")
      ENV["KAMAL_PERFORMER"] = "cole"
      ENV["KAMAL_DESTINATION"] = "staging"
      ENV["KAMAL_SERVICE"] = "dummy"

      Rake::Task["railwatch:deploy"].invoke("myref")

      expect(WebMock).to have_requested(:post, "http://railwatch.test/ingest/deploys").with { |req|
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
      stub_request(:post, "http://railwatch.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["railwatch:deploy"].invoke("myref")

      expect(WebMock).to have_requested(:post, "http://railwatch.test/ingest/deploys").with { |req|
        expect(JSON.parse(req.body)).to include("performer" => nil, "destination" => nil, "service" => nil)
        true
      }
    end
  end

  # Named, not referenced: the constant is defined by the rake file, which
  # before(:all) loads long after this file is parsed.
  describe "Railwatch::DeployMetadata" do
    subject(:metadata) { Railwatch::DeployMetadata }

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

  describe "railwatch:doctor" do
    # Captures the checklist rather than letting eleven lines per example
    # scroll past, and reports whether the task aborted.
    def run_doctor
      out = StringIO.new
      original_out, original_err = $stdout, $stderr
      $stdout = out
      $stderr = StringIO.new
      aborted = false
      begin
        Rake::Task["railwatch:doctor"].invoke
      rescue SystemExit
        aborted = true
      end
      [ out.string, aborted ]
    ensure
      $stdout, $stderr = original_out, original_err
    end

    before { stub_request(:get, "http://railwatch.test/ingest/ping").to_return(status: 200, body: "ok") }

    it "aborts and names tracked plaintext token files without printing the token" do
      allow(Railwatch::SecretSafety).to receive(:tracked_plaintext_token_files)
        .and_return([ ".env.production", "config/initializers/railwatch.rb" ])

      output, aborted = run_doctor

      expect(aborted).to be(true)
      expect(output).to include("✗ token storage: plaintext token found in tracked file(s): " \
                                ".env.production, config/initializers/railwatch.rb")
      expect(output).not_to include(Railwatch.config.token)
    end

    it "passes every fatal check and does not abort on a healthy install" do
      output, aborted = run_doctor

      expect(aborted).to be(false)
      expect(output).to include("✓ token: test-t... (10 chars)")
      expect(output).to include("✓ token storage: no tracked plaintext Railwatch token found")
      expect(output).to include("✓ ingest url: http://railwatch.test")
      expect(output).to include("✓ ingest reachable: GET http://railwatch.test/ingest/ping")
      expect(output).to include("Railwatch is wired up.")
    end

    it "confirms the request middleware is installed, and where in the stack" do
      output, = run_doctor

      expect(output).to match(/✓ request middleware: Railwatch::Middleware::Request at position \d+/)
    end

    it "confirms the engine is mounted and the beacon route resolves" do
      output, = run_doctor

      expect(output).to include("✓ engine mounted: POST /railwatch/beacon -> railwatch/beacon#create")
    end

    it "reports the deploy and which environment variable it came from" do
      output, = run_doctor

      expect(output).to include("✓ deploy: abc123 (from RAILWATCH_DEPLOY)")
    end

    it "reports a deploy detected from the checkout" do
      allow(Railwatch.config).to receive(:deploy_source).and_return("REVISION")

      output, = run_doctor

      expect(output).to include("✓ deploy: abc123 (from REVISION)")
    end

    it "reports the sample rates and the ignored record types" do
      Railwatch.config.ignore = [ :view_renders ]
      output, = run_doctor

      expect(output).to include("✓ sample rates: requests=1.0")
      expect(output).to include("✓ ignored record types: view_renders")
    ensure
      Railwatch.config.ignore = []
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
      allow(Railwatch::Profiler).to receive(:backend).and_return(nil)

      output, aborted = run_doctor

      expect(output).to include(%(✗ profiler backend: none -- add `gem "vernier"`))
      expect(aborted).to be(false)
    end

    it "names the entrypoint that calls startRailwatch()" do
      write_app_file("app/frontend/entrypoints/inertia.tsx", %(import "x"\nstartRailwatch()\n))

      output, = run_doctor

      expect(output).to include("✓ browser client imported: app/frontend/entrypoints/inertia.tsx")
    ensure
      cleanup_app_files
    end

    it "reports an entrypoint that never calls startRailwatch()" do
      write_app_file("app/frontend/entrypoints/inertia.tsx", %(import "x"\ncreateInertiaApp({})\n))

      output, aborted = run_doctor

      expect(output).to include("✗ browser client imported: no entrypoint in app/frontend/entrypoints calls startRailwatch()")
      expect(aborted).to be(false)
    ensure
      cleanup_app_files
    end

    it "reports optional integrations as missing without failing the check" do
      output, aborted = run_doctor

      expect(output).to include("✗ kamal post-deploy hook: not found")
      expect(output).to include("✗ browser client: not found")
      expect(output).to include("✗ test matchers: add `require \"railwatch/rspec\"`")
      expect(aborted).to be(false)
    end

    it "finds the Kamal hook, browser client, and rspec wiring when the app has them" do
      write_app_file(".kamal/hooks/post-deploy", "bin/rails railwatch:deploy\n")
      write_app_file("app/frontend/lib/railwatch.ts", "export function startRailwatch() {}\n")
      write_app_file("spec/rails_helper.rb", %(require "railwatch/rspec"\n))

      output, = run_doctor

      expect(output).to include("✓ kamal post-deploy hook:")
      expect(output).to include("✓ browser client:")
      expect(output).to include(%(✓ test matchers: spec/rails_helper.rb requires "railwatch/rspec"))
    ensure
      cleanup_app_files
    end

    it "finds the minitest wiring when the app has no spec/ directory" do
      write_app_file("test/test_helper.rb", %(require "railwatch/minitest"\n))

      output, = run_doctor

      expect(output).to include(%(✓ test matchers: test/test_helper.rb requires "railwatch/minitest"))
    ensure
      cleanup_app_files
    end

    it "aborts when no token is configured" do
      old_token = Railwatch.config.token
      Railwatch.config.token = nil

      output, aborted = run_doctor

      expect(output).to include("✗ token: RAILWATCH_TOKEN is not set")
      expect(aborted).to be(true)
    ensure
      Railwatch.config.token = old_token
    end

    it "aborts when the ingest host is unreachable" do
      stub_request(:get, "http://railwatch.test/ingest/ping").to_return(status: 500, body: "err")

      output, aborted = run_doctor

      expect(output).to include("✗ ingest reachable:")
      expect(aborted).to be(true)
    end

    it "reports an unset deploy without aborting" do
      old_deploy = Railwatch.config.deploy
      Railwatch.config.deploy = nil

      output, aborted = run_doctor

      expect(output).to include("✗ deploy: none: set RAILWATCH_DEPLOY")
      expect(aborted).to be(false)
    ensure
      Railwatch.config.deploy = old_deploy
    end
  end

  describe "railwatch:token" do
    it "points at the platform this gem already ships to, not the hosted default" do
      output = capture_task("railwatch:token")

      expect(output).to include("Railwatch platform: http://railwatch.test")
      expect(output).to include("http://railwatch.test/dashboard")
      expect(output).to include("RAILWATCH_TOKEN=lt_...")
    end

    it "tells a self-hosted app to set RAILWATCH_INGEST_URL as well" do
      output = capture_task("railwatch:token")

      expect(output).to include("RAILWATCH_INGEST_URL=http://railwatch.test")
    end

    it "omits RAILWATCH_INGEST_URL when the app ships to the hosted platform" do
      old = Railwatch.config.ingest_url
      Railwatch.config.ingest_url = "https://railwatch.rebulk.com"

      output = capture_task("railwatch:token")

      expect(output).to include("Railwatch platform: https://railwatch.rebulk.com")
      expect(output).not_to include("RAILWATCH_INGEST_URL")
    ensure
      Railwatch.config.ingest_url = old
    end
  end

  describe "railwatch:mcp" do
    it "prints the MCP endpoint on this app's own platform host" do
      output = capture_task("railwatch:mcp")

      expect(output).to include("Railwatch MCP server: http://railwatch.test/mcp")
      expect(output).to include("http://railwatch.test/settings/profile")
    end

    it "prints a paste-ready block for every supported client" do
      output = capture_task("railwatch:mcp")

      expect(output).to include(%(claude mcp add railwatch --transport http http://railwatch.test/mcp --header "Authorization: Bearer lnt_your_token_here"))
      expect(output).to include(%("args": ["-y", "mcp-remote", "http://railwatch.test/mcp", "--header", "Authorization: Bearer lnt_your_token_here"]))
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
