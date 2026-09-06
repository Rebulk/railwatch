# frozen_string_literal: true

module Nightrail
  # Deploy metadata gathered for nightrail:deploy. The commit list is what lets
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

  # Where this install's platform lives, derived from config.ingest_url:
  # nightrail:token and nightrail:mcp point at the same host the gem already
  # ships to, so a self-hosted app never gets told to visit nightrail.rebulk.com.
  class Endpoints
    HOSTED_HOST = "nightrail.rebulk.com"

    def initialize(config)
      @uri = URI.parse(config.ingest_url)
    end

    def host_url
      port = @uri.port && @uri.port != @uri.default_port ? ":#{@uri.port}" : ""
      "#{@uri.scheme}://#{@uri.host}#{port}"
    end

    def url(path)
      "#{host_url}#{path}"
    end

    def self_hosted?
      @uri.host != HOSTED_HOST
    end
  end
end

namespace :nightrail do
  desc "Upload build source maps privately: nightrail:sourcemaps[directory,delete] (directory defaults to public; delete defaults to false)"
  task :sourcemaps, [ :directory, :delete ] => :environment do |_task, args|
    require "nightrail/source_maps"
    directory = args[:directory] || ENV["NIGHTRAIL_SOURCEMAPS_DIR"] || "public"
    delete = (args[:delete] || ENV["NIGHTRAIL_SOURCEMAPS_DELETE"]) == "true"
    count = Nightrail::SourceMaps.new(Nightrail.config).upload(directory: directory, delete: delete)
    puts "Uploaded #{count} source maps for #{Nightrail.config.deploy}#{' and deleted acknowledged files' if delete}"
  end

  desc "Check that the app can reach Nightrail with the configured token"
  task status: :environment do
    unless Nightrail.config.token.present?
      abort "NIGHTRAIL_TOKEN is not set"
    end
    transport = Nightrail::Transport::Http.new(Nightrail.config)
    if transport.ping
      puts "Nightrail OK: #{Nightrail.config.ingest_url} (deploy=#{Nightrail.config.deploy || 'unset'}, server=#{Nightrail.config.server})"
    else
      abort "Nightrail unreachable at #{Nightrail.config.ingest_url}"
    end
  end

  desc "Check a Nightrail install end to end: token, ingest, middleware, routes, deploy, hooks, test helpers"
  task doctor: :environment do
    config = Nightrail.config
    blockers = []
    check = lambda do |ok, label, detail, fatal: false|
      puts "#{ok ? "✓" : "✗"} #{label}: #{detail}"
      blockers << label if !ok && fatal
      ok
    end

    token = config.token.to_s
    check.call(!token.empty?, "token",
               token.empty? ? "NIGHTRAIL_TOKEN is not set" : Nightrail::SecretSafety.token_preview(token),
               fatal: true)

    exposed_token_files = Nightrail::SecretSafety.tracked_plaintext_token_files(root: Rails.root)
    check.call(exposed_token_files.empty?, "token storage",
               exposed_token_files.empty? ? "no tracked plaintext Nightrail token found" :
                 "plaintext token found in tracked file(s): #{exposed_token_files.join(', ')}",
               fatal: true)

    ingest = URI.parse(config.ingest_url) rescue nil
    check.call(ingest.is_a?(URI::HTTP), "ingest url", config.ingest_url)

    transport_security = config.ingest_url_allowed?
    check.call(transport_security, "ingest transport security",
               if ingest&.scheme == "https"
                 "HTTPS with certificate verification"
               elsif transport_security
                 "plain HTTP explicitly allowed for #{ingest.host}"
               else
                 "plain HTTP refused; use HTTPS or set NIGHTRAIL_ALLOW_HTTP=true"
               end)

    check.call(Nightrail::Transport::Http.new(config).ping, "ingest reachable",
               "GET #{URI.join(config.ingest_url, '/ingest/ping')}", fatal: true)

    middleware = Rails.application.middleware.map(&:name)
    position = middleware.index("Nightrail::Middleware::Request")
    check.call(!position.nil?, "request middleware",
               position ? "Nightrail::Middleware::Request at position #{position}" : "not in the middleware stack")

    mount = Rails.application.routes.routes.find { |r| r.app.respond_to?(:app) && r.app.app == Nightrail::Engine }
    beacon = Nightrail::Engine.routes.routes.any? { |r| r.defaults[:controller] == "nightrail/beacon" && r.defaults[:action] == "create" }
    check.call(!mount.nil? && beacon, "engine mounted",
               mount ? "POST #{mount.path.spec}/beacon -> nightrail/beacon#create" : %(add `mount Nightrail::Engine, at: "/nightrail"` to config/routes.rb))

    source = config.deploy_source
    if source == "config/initializers/nightrail.rb"
      detected_source = nil
      detected = Nightrail::ReleaseDetector.detect(project_root: Rails.root) { |found| detected_source = found }
      source = detected_source if detected == config.deploy
    end
    check.call(config.deploy.present?, "deploy",
               config.deploy.present? ? "#{config.deploy} (from #{source})" : "none: set NIGHTRAIL_DEPLOY")

    check.call(true, "sample rates", config.sample.map { |kind, rate| "#{kind}=#{rate}" }.join(" "))
    check.call(true, "ignored record types", config.ignore.empty? ? "none" : config.ignore.join(", "))

    check.call(true, "interactive sessions",
               "console=#{config.capture_console ? 'captured' : 'quiet'} " \
               "runner scratch paths=#{config.interactive_runner_paths.join(' ')} " \
               "(a typed/piped runner ships its command record, not its exception)")

    hook = Rails.root.join(".kamal/hooks/post-deploy")
    check.call(hook.exist? && hook.read.include?("nightrail"), "kamal post-deploy hook",
               hook.exist? ? hook.to_s : "not found (only needed when deploying with Kamal)")

    client = Rails.root.join("app/frontend/lib/nightrail.ts")
    check.call(client.exist?, "browser client",
               client.exist? ? "#{client} (call startNightrail() from your Inertia entrypoint)" : "not found (only needed for Inertia visit timing)")

    # The client file existing is not the same as it running: startNightrail()
    # has to be called from an entrypoint or no visit is ever timed.
    entrypoints = Dir[Rails.root.join("app/frontend/entrypoints/*")].select { |f| File.file?(f) }
    started = entrypoints.select { |f| File.read(f).include?("startNightrail") }
    check.call(started.any?, "browser client imported",
               if started.any?
                 started.map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }.join(", ")
               elsif entrypoints.any?
                 "no entrypoint in app/frontend/entrypoints calls startNightrail()"
               else
                 "no app/frontend/entrypoints (only needed for Inertia visit timing)"
               end)

    backend = Nightrail::Profiler.backend
    check.call(!backend.nil?, "profiler backend",
               backend || %(none -- add `gem "vernier"` (Ruby >= 3.2) or `gem "stackprof"` to profile slow executions))

    rails_helper = Rails.root.join("spec/rails_helper.rb")
    test_helper = Rails.root.join("test/test_helper.rb")
    wired = if rails_helper.exist? && rails_helper.read.include?("nightrail/rspec")
      %(spec/rails_helper.rb requires "nightrail/rspec")
    elsif test_helper.exist? && test_helper.read.include?("nightrail/minitest")
      %(test/test_helper.rb requires "nightrail/minitest")
    end
    check.call(!wired.nil?, "test matchers", wired || %(add `require "nightrail/rspec"` (or "nightrail/minitest") -- see docs/testing.md))

    abort "\nnightrail:doctor failed: #{blockers.join(', ')}" if blockers.any?
    puts "\nNightrail is wired up."
  end

  desc "Print where to create an ingest token for this app's Nightrail platform"
  task token: :environment do
    base = Nightrail::Endpoints.new(Nightrail.config)
    puts <<~TEXT
      Nightrail platform: #{base.host_url}

      1. Sign in (or sign up) at #{base.url("/dashboard")}
      2. New application, then New environment (production, staging, ...)
      3. The environment's token (lt_...) is shown once, right after it is created.

      Then set it where this app reads its environment:

        NIGHTRAIL_TOKEN=lt_...#{"\n  NIGHTRAIL_INGEST_URL=#{base.host_url}" if base.self_hosted?}

      With Kamal:  bin/rails generate nightrail:install --prompt-token --kamal-secrets
      Verify:      bin/rails nightrail:doctor

      An existing environment's token can be rotated from its Settings page;
      the prefix shown in the UI is the first 12 characters of the token.
    TEXT
  end

  desc "Print ready-to-paste MCP client configuration for this app's Nightrail platform"
  task mcp: :environment do
    base = Nightrail::Endpoints.new(Nightrail.config)
    mcp = base.url("/mcp")
    token = "lnt_your_token_here"
    puts <<~TEXT
      Nightrail MCP server: #{mcp}

      An MCP token is per person, not per app: Settings -> Profile -> "API & MCP
      token" at #{base.url("/settings/profile")}. It starts with lnt_ and is
      shown once. Everything below is scoped to whatever accounts that user
      belongs to.

      Claude Code
        claude mcp add nightrail --transport http #{mcp} --header "Authorization: Bearer #{token}"

      Claude Desktop (claude_desktop_config.json) -- via the mcp-remote shim
        {
          "mcpServers": {
            "nightrail": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "#{mcp}", "--header", "Authorization: Bearer #{token}"]
            }
          }
        }

      Cursor (.cursor/mcp.json)
        {
          "mcpServers": {
            "nightrail": {
              "url": "#{mcp}",
              "headers": { "Authorization": "Bearer #{token}" }
            }
          }
        }

      VS Code (.vscode/mcp.json)
        {
          "servers": {
            "nightrail": {
              "type": "http",
              "url": "#{mcp}",
              "headers": { "Authorization": "Bearer #{token}" }
            }
          }
        }

      Zed (settings.json) -- via the mcp-remote shim
        {
          "context_servers": {
            "nightrail": {
              "source": "custom",
              "command": "npx",
              "args": ["-y", "mcp-remote", "#{mcp}", "--header", "Authorization: Bearer #{token}"]
            }
          }
        }

      Test it without a client
        curl -sS #{mcp} \\
          -H "Authorization: Bearer #{token}" \\
          -H "Content-Type: application/json" \\
          -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

      What it exposes: tools (applications, issues, slow routes, executions,
      logs, profiles, alerts, query plans, deploys, release health), prompts
      (triage_issue, slow_route, daily_summary), and resources -- including
      Nightrail's own docs at nightrail://docs/<name>. See docs/ai-and-mcp.md.
    TEXT
  end

  desc "Send deploy metadata to Nightrail: rake nightrail:deploy[ref,name,url]"
  task :deploy, [ :ref, :name, :url ] => :environment do |_t, args|
    deploy = Nightrail.config.deploy or abort "NIGHTRAIL_DEPLOY (or KAMAL_VERSION) is not set"
    abort "Plain HTTP ingest is disabled; use HTTPS or set NIGHTRAIL_ALLOW_HTTP=true" unless Nightrail.config.ingest_url_allowed?
    uri = URI.join(Nightrail.config.ingest_url, "/ingest/deploys")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{Nightrail.config.token}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(deploy: deploy, ref: args[:ref] || (`git rev-parse HEAD 2>/dev/null`.strip.presence),
                             name: args[:name], url: args[:url], server: Nightrail.config.server, timestamp: Time.now.utc.iso8601(6),
                             performer: ENV["KAMAL_PERFORMER"], destination: ENV["KAMAL_DESTINATION"],
                             service: ENV["KAMAL_SERVICE"], commits: Nightrail::DeployMetadata.commits)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
    res.is_a?(Net::HTTPSuccess) ? puts("Deploy #{deploy} recorded") : abort("Deploy failed: #{res.code} #{res.body}")
  end
end
