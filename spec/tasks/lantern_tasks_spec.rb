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

    it "invokes its ping exactly once per rake invocation" do
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

    it "posts the deploy payload exactly once per rake invocation" do
      stub_request(:post, "http://lantern.test/ingest/deploys").to_return(status: 200, body: "ok")

      Rake::Task["lantern:deploy"].invoke("myref", "myname", "myurl")

      expect(WebMock).to have_requested(:post, "http://lantern.test/ingest/deploys").times(1)
    end
  end
end
