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
end
