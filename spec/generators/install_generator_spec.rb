# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "rails/generators/testing/assertions"
require "generators/lantern/install/install_generator"
require "fileutils"

RSpec.describe Lantern::Generators::InstallGenerator do
  include Rails::Generators::Testing::Behavior
  include Rails::Generators::Testing::Assertions
  include FileUtils

  tests Lantern::Generators::InstallGenerator
  destination File.expand_path("../../tmp/install_generator", __dir__)
  # The install ends by invoking lantern:doctor, which loads the dummy app's
  # rake tasks and pings the ingest host. Only the example that asserts on it
  # wants that; every other example opts out here rather than repeating the flag.
  arguments %w[--no-doctor]

  before do
    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  it "creates config/initializers/lantern.rb with a Lantern.configure block" do
    run_generator

    initializer = File.join(destination_root, "config/initializers/lantern.rb")
    expect(File).to exist(initializer)
    expect(File.read(initializer)).to include("Lantern.configure do |c|")
  end

  it "mounts the Lantern engine at /lantern in config/routes.rb" do
    run_generator

    expect(File.read(File.join(destination_root, "config/routes.rb"))).to include('mount Lantern::Engine, at: "/lantern"')
  end

  it "does not create a Kamal hook or browser client when their host files/dirs are absent" do
    Dir.chdir(destination_root) { run_generator }

    expect(File).not_to exist(File.join(destination_root, ".kamal/hooks/post-deploy"))
    expect(File).not_to exist(File.join(destination_root, "app/frontend/lib/lantern.ts"))
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
    expect(File.read(hook)).to include("bin/rails lantern:deploy")
    expect(File.stat(hook).mode & 0o777).to eq(0o755)
  end

  it "creates the browser client only when app/frontend exists" do
    FileUtils.mkdir_p(File.join(destination_root, "app/frontend"))

    Dir.chdir(destination_root) { run_generator }

    expect(File).to exist(File.join(destination_root, "app/frontend/lib/lantern.ts"))
  end

  describe "wiring the Inertia entrypoint" do
    def write_entrypoint(name, contents)
      FileUtils.mkdir_p(File.join(destination_root, "app/frontend/entrypoints"))
      File.write(File.join(destination_root, "app/frontend/entrypoints", name), contents)
    end

    def entrypoint(name) = File.read(File.join(destination_root, "app/frontend/entrypoints", name))

    it "adds the import and the startLantern() call after the last import in inertia.tsx" do
      write_entrypoint("inertia.tsx", <<~TSX)
        import { createInertiaApp } from "@inertiajs/react"
        import { createRoot } from "react-dom/client"

        createInertiaApp({})
      TSX

      Dir.chdir(destination_root) { run_generator }

      body = entrypoint("inertia.tsx")
      expect(body).to include('import { startLantern } from "@/lib/lantern"')
      expect(body).to include("startLantern()")
      expect(body.index("startLantern()")).to be > body.index("react-dom/client")
      expect(body.index("startLantern()")).to be < body.index("createInertiaApp({})")
    end

    it "wires a .ts entrypoint when there is no .tsx one" do
      write_entrypoint("inertia.ts", %(import { createInertiaApp } from "@inertiajs/react"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.ts")).to include("startLantern()")
    end

    it "wires a .jsx entrypoint when there is no .tsx or .ts one" do
      write_entrypoint("inertia.jsx", %(import { createInertiaApp } from "@inertiajs/react"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.jsx")).to include("startLantern()")
    end

    it "does not add a second startLantern() call when run again" do
      write_entrypoint("inertia.tsx", %(import { createInertiaApp } from "@inertiajs/react"\n))

      Dir.chdir(destination_root) { run_generator }
      Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.tsx").scan("startLantern()").size).to eq(1)
    end

    it "prints instructions instead of editing when the entrypoint has no imports to anchor to" do
      write_entrypoint("inertia.tsx", %(createInertiaApp({})\n))

      output = Dir.chdir(destination_root) { run_generator }

      expect(entrypoint("inertia.tsx")).not_to include("startLantern")
      expect(output).to include("Add these two lines to app/frontend/entrypoints/inertia.tsx")
    end

    it "prints instructions when app/frontend exists but no Inertia entrypoint does" do
      FileUtils.mkdir_p(File.join(destination_root, "app/frontend"))

      output = Dir.chdir(destination_root) { run_generator }

      expect(output).to include("Add these two lines to app/frontend/entrypoints/inertia.tsx")
    end

    it "says nothing about the entrypoint when the app has no app/frontend at all" do
      output = Dir.chdir(destination_root) { run_generator }

      expect(output).not_to include("startLantern")
    end
  end

  describe "wiring the test helper" do
    def write_file(path, contents)
      full = File.join(destination_root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
      full
    end

    it "requires lantern/rspec after rspec/rails in spec/rails_helper.rb" do
      path = write_file("spec/rails_helper.rb", %(require "spec_helper"\nrequire "rspec/rails"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(path)).to eq(%(require "spec_helper"\nrequire "rspec/rails"\nrequire "lantern/rspec"\n))
    end

    it "does not add a second require when run again" do
      path = write_file("spec/rails_helper.rb", %(require "rspec/rails"\n))

      Dir.chdir(destination_root) { run_generator }
      Dir.chdir(destination_root) { run_generator }

      expect(File.read(path).scan(%(require "lantern/rspec")).size).to eq(1)
    end

    it "prints instructions instead of editing when rails_helper.rb has no rspec/rails require" do
      path = write_file("spec/rails_helper.rb", %(require "spec_helper"\n))

      output = Dir.chdir(destination_root) { run_generator }

      expect(File.read(path)).not_to include("lantern/rspec")
      expect(output).to include(%(Add `require "lantern/rspec"` to spec/rails_helper.rb))
    end

    it "requires lantern/minitest after rails/test_help when the app uses Minitest" do
      path = write_file("test/test_helper.rb", %(require_relative "../config/environment"\nrequire "rails/test_help"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(path)).to include(%(require "rails/test_help"\nrequire "lantern/minitest"\n))
    end

    it "prefers RSpec when both spec/rails_helper.rb and test/test_helper.rb exist" do
      rspec_path = write_file("spec/rails_helper.rb", %(require "rspec/rails"\n))
      minitest_path = write_file("test/test_helper.rb", %(require "rails/test_help"\n))

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(rspec_path)).to include("lantern/rspec")
      expect(File.read(minitest_path)).not_to include("lantern/minitest")
    end

    it "touches nothing when the app has neither helper" do
      output = Dir.chdir(destination_root) { run_generator }

      expect(output).not_to include("lantern/rspec")
      expect(output).not_to include("lantern/minitest")
    end
  end

  describe "--token / --url" do
    def env_file = File.join(destination_root, ".env")

    def install(*extra)
      Dir.chdir(destination_root) { run_generator(%w[--no-doctor --token=lt_abc123 --url=https://lantern.example.com] + extra) }
    end

    it "appends both variables to an existing .env, leaving what was there alone" do
      File.write(env_file, "FOO=bar\n")

      install

      expect(File.read(env_file)).to eq("FOO=bar\nLANTERN_TOKEN=lt_abc123\nLANTERN_INGEST_URL=https://lantern.example.com\n")
    end

    it "separates the appended block when the existing .env has no trailing newline" do
      File.write(env_file, "FOO=bar")

      install

      expect(File.read(env_file)).to eq("FOO=bar\nLANTERN_TOKEN=lt_abc123\nLANTERN_INGEST_URL=https://lantern.example.com\n")
    end

    it "creates .env when there is none but dotenv is in the Gemfile" do
      File.write(File.join(destination_root, "Gemfile"), %(source "https://rubygems.org"\ngem "dotenv-rails"\n))

      install

      expect(File.read(env_file)).to eq("LANTERN_TOKEN=lt_abc123\nLANTERN_INGEST_URL=https://lantern.example.com\n")
    end

    it "writes each variable once when run again" do
      File.write(env_file, "")

      install
      install

      expect(File.read(env_file).scan("LANTERN_TOKEN=").size).to eq(1)
    end

    it "leaves a variable the app already set alone" do
      File.write(env_file, "LANTERN_TOKEN=lt_existing\n")

      install

      expect(File.read(env_file)).to eq("LANTERN_TOKEN=lt_existing\nLANTERN_INGEST_URL=https://lantern.example.com\n")
    end

    it "prints the exact lines to paste, and writes no file, when the app has no dotenv" do
      output = install

      expect(File).not_to exist(env_file)
      expect(output).to include("LANTERN_TOKEN=lt_abc123")
      expect(output).to include("LANTERN_INGEST_URL=https://lantern.example.com")
      expect(output).to include(".kamal/secrets")
    end

    it "touches .env only when a value was passed" do
      File.write(env_file, "FOO=bar\n")

      Dir.chdir(destination_root) { run_generator }

      expect(File.read(env_file)).to eq("FOO=bar\n")
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

      expect(File.read(secrets_file)).to end_with("RAILS_MASTER_KEY=$(cat config/master.key)\nLANTERN_TOKEN=$LANTERN_TOKEN\n")
    end

    it "adds a whole env: secret: block when deploy.yml has none" do
      install("service: widgets\nimage: acme/widgets\n")

      expect(File.read(deploy_yml)).to eq(<<~YAML)
        service: widgets
        image: acme/widgets

        env:
          secret:
            - LANTERN_TOKEN
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
            - LANTERN_TOKEN
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
            - LANTERN_TOKEN
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
      expect(File.read(secrets_file).scan("LANTERN_TOKEN=").size).to eq(1)
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
    it "finishes by running lantern:doctor in process and printing its checklist" do
      stub_request(:get, "http://lantern.test/ingest/ping").to_return(status: 200, body: "ok")

      output = Dir.chdir(destination_root) { run_generator [] }

      expect(output).to include("bin/rails lantern:doctor")
      expect(output).to include("✓ token: test-t... (10 chars)")
      expect(output).to include("✓ ingest reachable:")
    end

    it "reports the failing checks without raising when the doctor aborts" do
      stub_request(:get, "http://lantern.test/ingest/ping").to_return(status: 500, body: "err")

      output = Dir.chdir(destination_root) { run_generator [] }

      expect(output).to include("✗ ingest reachable:")
      expect(output).to include("only picked up after a restart")
    end
  end

  describe "next steps" do
    it "tells you how to set the token with Kamal or credentials and how to verify the install" do
      output = Dir.chdir(destination_root) { run_generator }

      expect(output).to include("Set LANTERN_TOKEN")
      expect(output).to include(".kamal/secrets")
      expect(output).to include("Rails.application.credentials.dig(:lantern, :token)")
      expect(output).to include("LANTERN_INGEST_URL")
      expect(output).to include("bin/rails lantern:doctor")
      expect(output).to include("bin/rails lantern:token")
      expect(output).to include("bin/rails lantern:mcp")
      expect(output).to include("docs/testing.md")
    end
  end
end
