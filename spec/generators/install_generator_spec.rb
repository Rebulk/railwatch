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

  describe "next steps" do
    it "tells you how to set the token with Kamal or credentials and how to verify the install" do
      output = Dir.chdir(destination_root) { run_generator }

      expect(output).to include("Set LANTERN_TOKEN")
      expect(output).to include(".kamal/secrets")
      expect(output).to include("Rails.application.credentials.dig(:lantern, :token)")
      expect(output).to include("LANTERN_INGEST_URL")
      expect(output).to include("bin/rails lantern:doctor")
      expect(output).to include("docs/testing.md")
    end
  end
end
