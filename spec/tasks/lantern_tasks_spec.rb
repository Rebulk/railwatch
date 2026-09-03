# frozen_string_literal: true

require "spec_helper"
require "rake"

RSpec.describe "lantern rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("lantern:status")
  end

  after do
    Rake::Task["lantern:status"].reenable
    Rake::Task["lantern:deploy"].reenable
  end

  describe "lantern:status" do
    it "aborts when no token is configured" do
      old_token = Lantern.config.token
      Lantern.config.token = nil

      expect { Rake::Task["lantern:status"].invoke }.to raise_error(SystemExit)
    ensure
      Lantern.config.token = old_token
    end

    it "aborts when the ingest host is unreachable" do
      stub_request(:get, "http://lantern.test/ingest/ping").to_return(status: 500, body: "err")

      expect { Rake::Task["lantern:status"].invoke }.to raise_error(SystemExit)
    end

    it "pings the configured ingest host and prints the deploy and server when reachable" do
      stub_request(:get, "http://lantern.test/ingest/ping").to_return(status: 200, body: "ok")

      expect { Rake::Task["lantern:status"].invoke }.not_to raise_error
      expect(WebMock).to have_requested(:get, "http://lantern.test/ingest/ping").at_least_once
    end

    it "pending: invokes its ping exactly once per rake invocation" do
      pending "bug: Lantern::Engine (lib/lantern/engine.rb) registers lib/tasks/lantern_tasks.rake " \
              "twice for every task. Its explicit `rake_tasks do load File.expand_path(...) end` block " \
              "is redundant -- Rails::Engine#run_tasks_blocks (railties-8.1.3.1/lib/rails/engine.rb:685-686) " \
              "already auto-loads every *.rake file under an engine's lib/tasks directory by convention " \
              "(`paths[\"lib/tasks\"].existent.sort.each { |ext| load(ext) }`, run right after the explicit " \
              "rake_tasks blocks via `super`). Because Rake's `task name do .. end` APPENDS a block to an " \
              "existing task's actions instead of replacing them, lantern_tasks.rake being loaded twice " \
              "means Rake::Task[\"lantern:status\"].actions.size == 2 (confirmed by instrumenting Kernel#load " \
              "and Rails::Application#run_tasks_blocks: two `load` calls for the same absolute path, one from " \
              "Lantern::Engine's own block, one from Rails::Engine's automatic lib/tasks glob). A single " \
              "`rake lantern:status` invocation therefore pings and prints \"Lantern OK\" twice, and a single " \
              "`rake lantern:deploy` POSTs the deploy payload twice. Fix: delete the `rake_tasks do ... end` " \
              "block from lib/lantern/engine.rb entirely -- lib/tasks/lantern_tasks.rake is already picked up " \
              "by Rails::Engine's default convention with no explicit registration needed."

      stub_request(:get, "http://lantern.test/ingest/ping").to_return(status: 200, body: "ok")

      Rake::Task["lantern:status"].invoke

      expect(WebMock).to have_requested(:get, "http://lantern.test/ingest/ping").times(1)
    end
  end

  describe "lantern:deploy" do
    it "aborts when no deploy identifier is configured" do
      old_deploy = Lantern.config.deploy
      Lantern.config.deploy = nil

      expect { Rake::Task["lantern:deploy"].invoke }.to raise_error(SystemExit)
    ensure
      Lantern.config.deploy = old_deploy
    end

    it "posts the deploy, ref, name, url, and server with a bearer token" do
      stub_request(:post, "http://lantern.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["lantern:deploy"].invoke("myref", "myname", "myurl")

      expect(WebMock).to have_requested(:post, "http://lantern.test/ingest/deploys").with { |req|
        body = JSON.parse(req.body)
        expect(body).to include(
          "deploy" => "abc123",
          "ref" => "myref",
          "name" => "myname",
          "url" => "myurl",
          "server" => Lantern.config.server
        )
        expect(req.headers["Authorization"]).to eq("Bearer test-token")
        true
      }.at_least_once
    end

    it "pending: posts the deploy payload exactly once per rake invocation" do
      pending "bug: same double lib/tasks/lantern_tasks.rake registration described on the " \
              "lantern:status pending spec above -- a single `rake lantern:deploy` invocation POSTs " \
              "to /ingest/deploys twice, not once."

      stub_request(:post, "http://lantern.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["lantern:deploy"].invoke("myref", "myname", "myurl")

      expect(WebMock).to have_requested(:post, "http://lantern.test/ingest/deploys").times(1)
    end
  end
end
