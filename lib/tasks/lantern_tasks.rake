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

  # Where this install's platform lives, derived from config.ingest_url:
  # lantern:token and lantern:mcp point at the same host the gem already
  # ships to, so a self-hosted app never gets told to visit lantern.rebulk.com.
  class Endpoints
    HOSTED_HOST = "lantern.rebulk.com"

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

namespace :lantern do
  desc "Upload build source maps privately: lantern:sourcemaps[directory,delete] (directory defaults to public; delete defaults to false)"
  task :sourcemaps, [ :directory, :delete ] => :environment do |_task, args|
    require "lantern/source_maps"
    directory = args[:directory] || ENV["LANTERN_SOURCEMAPS_DIR"] || "public"
    delete = (args[:delete] || ENV["LANTERN_SOURCEMAPS_DELETE"]) == "true"
    count = Lantern::SourceMaps.new(Lantern.config).upload(directory: directory, delete: delete)
    puts "Uploaded #{count} source maps for #{Lantern.config.deploy}#{' and deleted acknowledged files' if delete}"
  end

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
               token.empty? ? "LANTERN_TOKEN is not set" : Lantern::SecretSafety.token_preview(token),
               fatal: true)

    exposed_token_files = Lantern::SecretSafety.tracked_plaintext_token_files(root: Rails.root)
    check.call(exposed_token_files.empty?, "token storage",
               exposed_token_files.empty? ? "no tracked plaintext Lantern token found" :
                 "plaintext token found in tracked file(s): #{exposed_token_files.join(', ')}",
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

    check.call(true, "interactive sessions",
               "console=#{config.capture_console ? 'captured' : 'quiet'} " \
               "runner scratch paths=#{config.interactive_runner_paths.join(' ')} " \
               "(a typed/piped runner ships its command record, not its exception)")

    hook = Rails.root.join(".kamal/hooks/post-deploy")
    check.call(hook.exist? && hook.read.include?("lantern"), "kamal post-deploy hook",
               hook.exist? ? hook.to_s : "not found (only needed when deploying with Kamal)")

    client = Rails.root.join("app/frontend/lib/lantern.ts")
    check.call(client.exist?, "browser client",
               client.exist? ? "#{client} (call startLantern() from your Inertia entrypoint)" : "not found (only needed for Inertia visit timing)")

    # The client file existing is not the same as it running: startLantern()
    # has to be called from an entrypoint or no visit is ever timed.
    entrypoints = Dir[Rails.root.join("app/frontend/entrypoints/*")].select { |f| File.file?(f) }
    started = entrypoints.select { |f| File.read(f).include?("startLantern") }
    check.call(started.any?, "browser client imported",
               if started.any?
                 started.map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }.join(", ")
               elsif entrypoints.any?
                 "no entrypoint in app/frontend/entrypoints calls startLantern()"
               else
                 "no app/frontend/entrypoints (only needed for Inertia visit timing)"
               end)

    backend = Lantern::Profiler.backend
    check.call(!backend.nil?, "profiler backend",
               backend || %(none -- add `gem "vernier"` (Ruby >= 3.2) or `gem "stackprof"` to profile slow executions))

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

  desc "Print where to create an ingest token for this app's Lantern platform"
  task token: :environment do
    base = Lantern::Endpoints.new(Lantern.config)
    puts <<~TEXT
      Lantern platform: #{base.host_url}

      1. Sign in (or sign up) at #{base.url("/dashboard")}
      2. New application, then New environment (production, staging, ...)
      3. The environment's token (lt_...) is shown once, right after it is created.

      Then set it where this app reads its environment:

        LANTERN_TOKEN=lt_...#{"\n  LANTERN_INGEST_URL=#{base.host_url}" if base.self_hosted?}

      With Kamal:  bin/rails generate lantern:install --prompt-token --kamal-secrets
      Verify:      bin/rails lantern:doctor

      An existing environment's token can be rotated from its Settings page;
      the prefix shown in the UI is the first 12 characters of the token.
    TEXT
  end

  desc "Print ready-to-paste MCP client configuration for this app's Lantern platform"
  task mcp: :environment do
    base = Lantern::Endpoints.new(Lantern.config)
    mcp = base.url("/mcp")
    token = "lnt_your_token_here"
    puts <<~TEXT
      Lantern MCP server: #{mcp}

      An MCP token is per person, not per app: Settings -> Profile -> "API & MCP
      token" at #{base.url("/settings/profile")}. It starts with lnt_ and is
      shown once. Everything below is scoped to whatever accounts that user
      belongs to.

      Claude Code
        claude mcp add lantern --transport http #{mcp} --header "Authorization: Bearer #{token}"

      Claude Desktop (claude_desktop_config.json) -- via the mcp-remote shim
        {
          "mcpServers": {
            "lantern": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "#{mcp}", "--header", "Authorization: Bearer #{token}"]
            }
          }
        }

      Cursor (.cursor/mcp.json)
        {
          "mcpServers": {
            "lantern": {
              "url": "#{mcp}",
              "headers": { "Authorization": "Bearer #{token}" }
            }
          }
        }

      VS Code (.vscode/mcp.json)
        {
          "servers": {
            "lantern": {
              "type": "http",
              "url": "#{mcp}",
              "headers": { "Authorization": "Bearer #{token}" }
            }
          }
        }

      Zed (settings.json) -- via the mcp-remote shim
        {
          "context_servers": {
            "lantern": {
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
      Lantern's own docs at lantern://docs/<name>. See docs/ai-and-mcp.md.
    TEXT
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
