# frozen_string_literal: true

module Lantern
  # Deploy metadata gathered for lantern:deploy. The commit list is what lets
  # the platform show a diff of what actually shipped between two deploys; it
  # comes back empty inside an app container, which has the code but not the
  # git history (the Kamal post-deploy hook runs on the deployer, which does).
  module DeployMetadata
    FORMAT = "%H%x1f%an%x1f%s%x1f%cI"
    MAX_COMMITS = 50

    module_function

    # Newest first, capped at MAX_COMMITS.
    def commits
      return [] unless File.exist?(".git")

      git_log.each_line.filter_map do |line|
        sha, author, message, at = line.chomp.split("\x1f")
        { sha: sha, author: author, message: message, at: at } unless sha.nil? || sha.empty?
      end
    end

    def git_log
      `git log -n #{MAX_COMMITS} --format='#{FORMAT}' 2>/dev/null`
    rescue StandardError
      ""
    end
  end
end

namespace :lantern do
  desc "Check that the app can reach Lantern with the configured token"
  task status: :environment do
    unless Lantern.config.token.present?
      abort "LANTERN_TOKEN is not set"
    end
    transport = Lantern::Transport::Http.new(Lantern.config)
    if transport.ping
      puts "Lantern OK: #{Lantern.config.ingest_url} (deploy=#{Lantern.config.deploy || 'unset'}, server=#{Lantern.config.server})"
    else
      abort "Lantern unreachable at #{Lantern.config.ingest_url}"
    end
  end

  desc "Check a Lantern install end to end: token, ingest, middleware, routes, deploy, hooks, test helpers"
  task doctor: :environment do
    config = Lantern.config
    blockers = []
    check = lambda do |ok, label, detail, fatal: false|
      puts "#{ok ? "✓" : "✗"} #{label}: #{detail}"
      blockers << label if !ok && fatal
      ok
    end

    token = config.token.to_s
    check.call(!token.empty?, "token",
               token.empty? ? "LANTERN_TOKEN is not set" : "#{token[0, 6]}... (#{token.length} chars)",
               fatal: true)

    ingest = URI.parse(config.ingest_url) rescue nil
    check.call(ingest.is_a?(URI::HTTP), "ingest url", config.ingest_url)

    check.call(Lantern::Transport::Http.new(config).ping, "ingest reachable",
               "GET #{URI.join(config.ingest_url, '/ingest/ping')}", fatal: true)

    middleware = Rails.application.middleware.map(&:name)
    position = middleware.index("Lantern::Middleware::Request")
    check.call(!position.nil?, "request middleware",
               position ? "Lantern::Middleware::Request at position #{position}" : "not in the middleware stack")

    mount = Rails.application.routes.routes.find { |r| r.app.respond_to?(:app) && r.app.app == Lantern::Engine }
    beacon = Lantern::Engine.routes.routes.any? { |r| r.defaults[:controller] == "lantern/beacon" && r.defaults[:action] == "create" }
    check.call(!mount.nil? && beacon, "engine mounted",
               mount ? "POST #{mount.path.spec}/beacon -> lantern/beacon#create" : %(add `mount Lantern::Engine, at: "/lantern"` to config/routes.rb))

    # Reported honestly: the env var is only credited when it is the value
    # config.deploy actually ended up with.
    source = %w[LANTERN_DEPLOY KAMAL_VERSION GIT_REV].find { |key| ENV[key] == config.deploy } || "config/initializers/lantern.rb"
    check.call(config.deploy.present?, "deploy",
               config.deploy.present? ? "#{config.deploy} (from #{source})" : "unset -- charts will have no deploy markers")

    check.call(true, "sample rates", config.sample.map { |kind, rate| "#{kind}=#{rate}" }.join(" "))
    check.call(true, "ignored record types", config.ignore.empty? ? "none" : config.ignore.join(", "))

    hook = Rails.root.join(".kamal/hooks/post-deploy")
    check.call(hook.exist? && hook.read.include?("lantern"), "kamal post-deploy hook",
               hook.exist? ? hook.to_s : "not found (only needed when deploying with Kamal)")

    client = Rails.root.join("app/frontend/lib/lantern.ts")
    check.call(client.exist?, "browser client",
               client.exist? ? "#{client} (call startLantern() from your Inertia entrypoint)" : "not found (only needed for Inertia visit timing)")

    rails_helper = Rails.root.join("spec/rails_helper.rb")
    test_helper = Rails.root.join("test/test_helper.rb")
    wired = if rails_helper.exist? && rails_helper.read.include?("lantern/rspec")
      %(spec/rails_helper.rb requires "lantern/rspec")
    elsif test_helper.exist? && test_helper.read.include?("lantern/minitest")
      %(test/test_helper.rb requires "lantern/minitest")
    end
    check.call(!wired.nil?, "test matchers", wired || %(add `require "lantern/rspec"` (or "lantern/minitest") -- see docs/testing.md))

    abort "\nlantern:doctor failed: #{blockers.join(', ')}" if blockers.any?
    puts "\nLantern is wired up."
  end

  desc "Send deploy metadata to Lantern: rake lantern:deploy[ref,name,url]"
  task :deploy, [ :ref, :name, :url ] => :environment do |_t, args|
    deploy = Lantern.config.deploy or abort "LANTERN_DEPLOY (or KAMAL_VERSION) is not set"
    uri = URI.join(Lantern.config.ingest_url, "/ingest/deploys")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{Lantern.config.token}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(deploy: deploy, ref: args[:ref] || (`git rev-parse HEAD 2>/dev/null`.strip.presence),
                             name: args[:name], url: args[:url], server: Lantern.config.server, timestamp: Time.now.utc.iso8601(6),
                             performer: ENV["KAMAL_PERFORMER"], destination: ENV["KAMAL_DESTINATION"],
                             service: ENV["KAMAL_SERVICE"], commits: Lantern::DeployMetadata.commits)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
    res.is_a?(Net::HTTPSuccess) ? puts("Deploy #{deploy} recorded") : abort("Deploy failed: #{res.code} #{res.body}")
  end
end
