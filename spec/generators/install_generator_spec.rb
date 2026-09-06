# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "rails/generators/testing/assertions"
require "generators/nightrail/install/install_generator"
require "fileutils"

RSpec.describe Nightrail::Generators::InstallGenerator do
  include Rails::Generators::Testing::Behavior
  include Rails::Generators::Testing::Assertions
  include FileUtils

  tests Nightrail::Generators::InstallGenerator
  destination File.expand_path("../../tmp/install_generator", __dir__)
  # The install ends by invoking nightrail:doctor, which loads the dummy app's
  # rake tasks and pings the ingest host. Only the example that asserts on it
  # wants that; every other example opts out here rather than repeating the flag.
  arguments %w[--no-doctor]

  before do
    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  it "creates config/initializers/nightrail.rb with a Nightrail.configure block" do
    run_generator

    initializer = File.join(destination_root, "config/initializers/nightrail.rb")
    expect(File).to exist(initializer)
    expect(File.read(initializer)).to include("Nightrail.configure do |c|")
  end

  it "mounts the Nightrail engine at /nightrail in config/routes.rb" do
    run_generator

    expect(File.read(File.join(destination_root, "config/routes.rb"))).to include('mount Nightrail::Engine, at: "/nightrail"')
  end

  it "does not create a Kamal hook or browser client when their host files/dirs are absent" do
    Dir.chdir(destination_root) { run_generator }

    expect(File).not_to exist(File.join(destination_root, ".kamal/hooks/post-deploy"))
    expect(File).not_to exist(File.join(destination_root, "app/frontend/lib/nightrail.ts"))
  end

  it "creates an executable Kamal post-deploy hook only when config/deploy.yml exists" do
    File.write(File.join(destination_root, "config/deploy.yml"), "service: dummy\n")

    # create_kamal_hook checks File.exist?("config/deploy.yml") relative to
    # the process's cwd, not destination_root -- true for a real `bin/rails
    # generate` invocation (cwd is always the app root), so the test has to
    # match that by chdir-ing into destination_root itself.
    Dir.chdir(destination_root) { run_generator }

    hook = File.join(destination_root, ".kamal/hooks/post-deploy")
    expect(File).to exist(hook)
    expect(File.read(hook)).to include("bin/rails nightrail:deploy")
    expect(File.stat(hook).mode & 0o777).to eq(0o755)
  end

  it "creates the browser client only when app/frontend exists" do
    FileUtils.mkdir_p(File.join(destination_root, "app/frontend"))

    Dir.chdir(destination_root) { run_generator }

    expect(File).to exist(File.join(destination_root, "app/frontend/lib/nightrail.ts"))
  end

  describe "wiring the Inertia entrypoint" do
    def write_entrypoint(name, contents)
      FileUtils.mkdir_p(File.join(destination_root, "app/frontend/entrypoints"))
      File.write(File.join(destination_root, "app/frontend/entrypoints", name), contents)
    end

    def entrypoint(name) = File.read(File.join(destination_root, "app/frontend/entrypoints", name))

    it "adds the import and the startNightrail() call after the last import in inertia.tsx" do
      write_entrypoint("inertia.tsx", <<~TSX)
        import { createInertiaApp } from "@inertiajs/react"
        import { createRoot } from "react-dom/client"

        createInertiaApp({})
      TSX

      Dir.chdir(destination_root) { run_generator }

      body = entrypoint("inertia.tsx")
      expect(body).to include('import { startNightrail } from "@/lib/nightrail"')
      expect(body).to include("startNightrail()")
      expect(body.index("startNightrail()")).to be > body.index("react-dom/client")
      expect(body.index("startNightrail()")).to be < body.index("createInertiaApp({})")
    end

    it "wires a .ts entrypoint when there is no .tsx one" do
      write_entrypoint("inertia.ts", %(import { createInertiaApp } from "@inertiajs/react"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.ts")).to include("startNightrail()")
    end

    it "wires a .jsx entrypoint when there is no .tsx or .ts one" do
      write_entrypoint("inertia.jsx", %(import { createInertiaApp } from "@inertiajs/react"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.jsx")).to include("startNightrail()")
    end

    it "does not add a second startNightrail() call when run again" do
      write_entrypoint("inertia.tsx", %(import { createInertiaApp } from "@inertiajs/react"\n))

      Dir.chdir(destination_root) { run_generator }
      Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.tsx").scan("startNightrail()").size).to eq(1)
    end

    it "prints instructions instead of editing when the entrypoint has no imports to anchor to" do
      write_entrypoint("inertia.tsx", %(createInertiaApp({})\n))

      output = Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.tsx")).not_to include("startNightrail")
      expect(output).to include("Add these two lines to app/frontend/entrypoints/inertia.tsx")
    end

    it "prints instructions when app/frontend exists but no Inertia entrypoint does" do
      FileUtils.mkdir_p(File.join(destination_root, "app/frontend"))

      output = Dir.chdir(destination_root) { run_generator }

      expect(output).to include("Add these two lines to app/frontend/entrypoints/inertia.tsx")
    end

    it "says nothing about the entrypoint when the app has no app/frontend at all" do
      output = Dir.chdir(destination_root) { run_generator }

      expect(output).not_to include("startNightrail")
    end
  end

  describe "wiring the test helper" do
    def write_file(path, contents)
      full = File.join(destination_root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
      full
    end

    it "requires nightrail/rspec after rspec/rails in spec/rails_helper.rb" do
      path = write_file("spec/rails_helper.rb", %(require "spec_helper"\nrequire "rspec/rails"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(path)).to eq(%(require "spec_helper"\nrequire "rspec/rails"\nrequire "nightrail/rspec"\n))
    end

    it "does not add a second require when run again" do
      path = write_file("spec/rails_helper.rb", %(require "rspec/rails"\n))

      Dir.chdir(destination_root) { run_generator }
      Dir.chdir(destination_root) { run_generator }

      expect(File.read(path).scan(%(require "nightrail/rspec")).size).to eq(1)
    end

    it "prints instructions instead of editing when rails_helper.rb has no rspec/rails require" do
      path = write_file("spec/rails_helper.rb", %(require "spec_helper"\n))

      output = Dir.chdir(destination_root) { run_generator }

      expect(File.read(path)).not_to include("nightrail/rspec")
      expect(output).to include(%(Add `require "nightrail/rspec"` to spec/rails_helper.rb))
    end

    it "requires nightrail/minitest after rails/test_help when the app uses Minitest" do
      path = write_file("test/test_helper.rb", %(require_relative "../config/environment"\nrequire "rails/test_help"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(path)).to include(%(require "rails/test_help"\nrequire "nightrail/minitest"\n))
    end

    it "prefers RSpec when both spec/rails_helper.rb and test/test_helper.rb exist" do
      rspec_path = write_file("spec/rails_helper.rb", %(require "rspec/rails"\n))
      minitest_path = write_file("test/test_helper.rb", %(require "rails/test_help"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(rspec_path)).to include("nightrail/rspec")
      expect(File.read(minitest_path)).not_to include("nightrail/minitest")
    end

    it "touches nothing when the app has neither helper" do
      output = Dir.chdir(destination_root) { run_generator }

      expect(output).not_to include("nightrail/rspec")
      expect(output).not_to include("nightrail/minitest")
    end
  end

  describe "--token / --url" do
    def env_file = File.join(destination_root, ".env")

    def install(*extra)
      Dir.chdir(destination_root) { run_generator(%w[--no-doctor --token=lt_abc123 --url=https://nightrail.example.com] + extra) }
    end

    it "appends both variables to an existing .env, leaving what was there alone" do
      File.write(env_file, "FOO=bar\n")

      install

      expect(File.read(env_file)).to eq("FOO=bar\nNIGHTRAIL_TOKEN=lt_abc123\nNIGHTRAIL_INGEST_URL=https://nightrail.example.com\n")
    end

    it "separates the appended block when the existing .env has no trailing newline" do
      File.write(env_file, "FOO=bar")

      install

      expect(File.read(env_file)).to eq("FOO=bar\nNIGHTRAIL_TOKEN=lt_abc123\nNIGHTRAIL_INGEST_URL=https://nightrail.example.com\n")
    end

    it "creates .env when there is none but dotenv is in the Gemfile" do
      File.write(File.join(destination_root, "Gemfile"), %(source "https://rubygems.org"\ngem "dotenv-rails"\n))

      install

      expect(File.read(env_file)).to eq("NIGHTRAIL_TOKEN=lt_abc123\nNIGHTRAIL_INGEST_URL=https://nightrail.example.com\n")
    end

    it "writes each variable once when run again" do
      File.write(env_file, "")

      install
      install

      expect(File.read(env_file).scan("NIGHTRAIL_TOKEN=").size).to eq(1)
    end

    it "leaves a variable the app already set alone" do
      File.write(env_file, "NIGHTRAIL_TOKEN=lt_existing\n")

      install

      expect(File.read(env_file)).to eq("NIGHTRAIL_TOKEN=lt_existing\nNIGHTRAIL_INGEST_URL=https://nightrail.example.com\n")
    end

    it "prints only a token prefix, and writes no file, when the app has no dotenv" do
      output = install

      expect(File).not_to exist(env_file)
      expect(output).to include("NIGHTRAIL_TOKEN=lt_abc... (9 chars) (value hidden)")
      expect(output).not_to include("NIGHTRAIL_TOKEN=lt_abc123")
      expect(output).to include("NIGHTRAIL_INGEST_URL=https://nightrail.example.com")
      expect(output).to include(".kamal/secrets")
    end

    it "touches .env only when neither an option nor environment token was supplied" do
      File.write(env_file, "FOO=bar\n")
      token = ENV.delete("NIGHTRAIL_TOKEN")

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(env_file)).to eq("FOO=bar\n")
    ensure
      ENV["NIGHTRAIL_TOKEN"] = token if token
    end

    it "reads an exported token without putting it in command arguments" do
      File.write(env_file, "")
      previous_token = ENV["NIGHTRAIL_TOKEN"]
      ENV["NIGHTRAIL_TOKEN"] = "lt_from_environment"

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(env_file)).to eq("NIGHTRAIL_TOKEN=lt_from_environment\n")
    ensure
      previous_token.nil? ? ENV.delete("NIGHTRAIL_TOKEN") : ENV["NIGHTRAIL_TOKEN"] = previous_token
    end

    it "warns about the legacy command-line token without printing it" do
      output = install

      expect(output).to include("--token exposes lt_abc... (9 chars) in process arguments")
      expect(output).not_to include("--token exposes lt_abc123")
    end

    it "refuses a token when .env is tracked, while still writing the non-secret URL" do
      Dir.chdir(destination_root) do
        system("git", "init", "-q")
        File.write(".env", "FOO=bar\n")
        system("git", "add", "-f", ".env")
      end

      output = install

      expect(output).to include("Refusing to write lt_abc... (9 chars) to .env")
      expect(File.read(env_file)).to eq("FOO=bar\nNIGHTRAIL_INGEST_URL=https://nightrail.example.com\n")
      expect(File.read(env_file)).not_to include("lt_abc123")
    end

    it "refuses a token when .env is not ignored" do
      Dir.chdir(destination_root) { system("git", "init", "-q") }
      File.write(File.join(destination_root, "Gemfile"), %(gem "dotenv-rails"\n))

      output = install

      expect(output).to include("Git does not confirm that .env is ignored")
      expect(File.read(env_file)).to eq("NIGHTRAIL_INGEST_URL=https://nightrail.example.com\n")
    end

    it "writes a token when the repository explicitly ignores .env" do
      Dir.chdir(destination_root) do
        system("git", "init", "-q")
        File.write(".gitignore", ".env\n")
        File.write(".env", "")
      end

      install

      expect(File.read(env_file)).to include("NIGHTRAIL_TOKEN=lt_abc123\n")
    end

    it "reads a token from stdin without echoing it" do
      File.write(env_file, "")
      previous_stdin = $stdin
      $stdin = StringIO.new("lt_from_stdin\n")

      output = Dir.chdir(destination_root) do
        run_generator %w[--no-doctor --token-stdin --url=https://nightrail.example.com]
      end

      expect(File.read(env_file)).to include("NIGHTRAIL_TOKEN=lt_from_stdin\n")
      expect(output).not_to include("lt_from_stdin")
    ensure
      $stdin = previous_stdin if previous_stdin
    end
  end

  describe "--kamal-secrets" do
    def deploy_yml = File.join(destination_root, "config/deploy.yml")
    def secrets_file = File.join(destination_root, ".kamal/secrets")

    def install(deploy_contents)
      File.write(deploy_yml, deploy_contents)
      FileUtils.mkdir_p(File.join(destination_root, ".kamal"))
      File.write(secrets_file, "# Secrets used by config/deploy.yml\nRAILS_MASTER_KEY=$(cat config/master.key)\n") unless File.exist?(secrets_file)
      Dir.chdir(destination_root) { run_generator %w[--no-doctor --kamal-secrets] }
    end

    it "appends the shell-expanded token to .kamal/secrets" do
      install("service: widgets\n")

      expect(File.read(secrets_file)).to end_with("RAILS_MASTER_KEY=$(cat config/master.key)\nNIGHTRAIL_TOKEN=$NIGHTRAIL_TOKEN\n")
    end

    it "adds a whole env: secret: block when deploy.yml has none" do
      install("service: widgets\nimage: acme/widgets\n")

      expect(File.read(deploy_yml)).to eq(<<~YAML)
        service: widgets
        image: acme/widgets

        env:
          secret:
            - NIGHTRAIL_TOKEN
      YAML
    end

    it "adds a secret: list under an env: block that only has clear:" do
      install(<<~YAML)
        service: widgets
        env:
          clear:
            RAILS_MAX_THREADS: 5
      YAML

      expect(File.read(deploy_yml)).to eq(<<~YAML)
        service: widgets
        env:
          secret:
            - NIGHTRAIL_TOKEN
          clear:
            RAILS_MAX_THREADS: 5
      YAML
    end

    it "appends to an existing secret list, above the clear block, keeping comments" do
      install(<<~YAML)
        service: widgets
        env:
          secret:
            # Read from .kamal/secrets.
            - RAILS_MASTER_KEY
          clear:
            RAILS_MAX_THREADS: 5
        # trailing note
      YAML

      expect(File.read(deploy_yml)).to eq(<<~YAML)
        service: widgets
        env:
          secret:
            # Read from .kamal/secrets.
            - RAILS_MASTER_KEY
            - NIGHTRAIL_TOKEN
          clear:
            RAILS_MAX_THREADS: 5
        # trailing note
      YAML
    end

    it "changes nothing on a second run" do
      original = "service: widgets\nenv:\n  secret:\n    - RAILS_MASTER_KEY\n"
      install(original)
      after_first = File.read(deploy_yml)

      Dir.chdir(destination_root) { run_generator %w[--no-doctor --kamal-secrets] }

      expect(File.read(deploy_yml)).to eq(after_first)
      expect(File.read(secrets_file).scan("NIGHTRAIL_TOKEN=").size).to eq(1)
    end

    it "says what to do by hand when there is no .kamal/secrets" do
      File.write(deploy_yml, "service: widgets\n")

      output = Dir.chdir(destination_root) { run_generator %w[--no-doctor --kamal-secrets] }

      expect(output).to include("no .kamal/secrets found")
      expect(File.read(deploy_yml)).to eq("service: widgets\n")
    end

    it "leaves deploy.yml alone without the flag" do
      File.write(deploy_yml, "service: widgets\n")

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(deploy_yml)).to eq("service: widgets\n")
    end
  end

  describe "running the doctor" do
    it "finishes by running nightrail:doctor in process and printing its checklist" do
      stub_request(:get, "http://nightrail.test/ingest/ping").to_return(status: 200, body: "ok")

      output = Dir.chdir(destination_root) { run_generator [] }

      expect(output).to include("bin/rails nightrail:doctor")
      expect(output).to include("✓ token: test-t... (10 chars)")
      expect(output).to include("✓ ingest reachable:")
    end

    it "reports the failing checks without raising when the doctor aborts" do
      stub_request(:get, "http://nightrail.test/ingest/ping").to_return(status: 500, body: "err")

      output = Dir.chdir(destination_root) { run_generator [] }

      expect(output).to include("✗ ingest reachable:")
      expect(output).to include("only picked up after a restart")
    end
  end

  describe "next steps" do
    it "tells you how to set the token with Kamal or credentials and how to verify the install" do
      output = Dir.chdir(destination_root) { run_generator }

      expect(output).to include("Set NIGHTRAIL_TOKEN")
      expect(output).to include(".kamal/secrets")
      expect(output).to include("Rails.application.credentials.dig(:nightrail, :token)")
      expect(output).to include("NIGHTRAIL_INGEST_URL")
      expect(output).to include("bin/rails nightrail:doctor")
      expect(output).to include("bin/rails nightrail:token")
      expect(output).to include("bin/rails nightrail:mcp")
      expect(output).to include("docs/testing.md")
    end
  end
end
