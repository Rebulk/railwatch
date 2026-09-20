# frozen_string_literal: true

module Railwatch
  # Deploy metadata gathered for railwatch:deploy. The commit list is what lets
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

  # What the embedded telemetry database is costing on disk, and the one-time
  # conversion that lets pruning give that cost back.
  #
  # Deleting rows does not shrink a SQLite file. The pages go on the freelist
  # and are reused by later inserts, and the only way back to the filesystem
  # is auto_vacuum=incremental plus PRAGMA incremental_vacuum -- which
  # PruneTelemetryJob now runs after every prune. A database can only enter
  # that mode while it is still empty (EnableIncrementalVacuum does that for
  # every telemetry database created since it shipped) or through a full
  # VACUUM, which is what this offers to an older one.
  class TelemetryDisk
    # Deliberately pessimistic, and said out loud as an estimate: VACUUM
    # rewrites the whole file, and what that costs is the operator's disk,
    # not ours to know.
    VACUUM_BYTES_PER_SECOND = 50 * 1024 * 1024

    # nil, having said why, for an install with no telemetry database to
    # talk about.
    def self.open
      unless Railwatch.config.local?
        puts "Railwatch reports over HTTP here (transport = :http), so this app has no telemetry database; nothing to vacuum."
        return nil
      end

      environment = Railwatch::Environment.current
      return new(environment) if environment.with_telemetry { Railwatch::TelemetryRecord.sqlite? }

      puts "The railwatch_telemetry database is not SQLite; auto_vacuum does not apply."
      nil
    end

    def initialize(environment)
      @environment = environment
    end

    def report
      with_telemetry do
        <<~TEXT.chomp
          Railwatch telemetry database
            file    #{path}
            size    #{human(file_bytes)}#{" + #{human(wal_bytes)} WAL" if wal_bytes.positive?}
            mode    auto_vacuum=#{mode}
            free    #{freelist} pages (#{human(freelist * page_size)}) on the freelist
        TEXT
      end
    end

    def advice
      with_telemetry do
        if mode != :incremental
          "\nPruning cannot return space to the filesystem in this mode: every page it frees stays in this file.\n" \
            "`bin/rails railwatch:vacuum` converts the database to incremental auto-vacuum with a full VACUUM. " \
            "That rewrites all #{human(file_bytes)}, needs about that much free disk for the temporary copy, and " \
            "holds the write lock for roughly #{estimate}. Telemetry written while it runs waits for it."
        elsif freelist.positive?
          "\nThe nightly prune returns up to #{human(Railwatch::PruneTelemetryJob::VACUUM_PAGES_PER_SLICE * Railwatch::PruneTelemetryJob::VACUUM_SLICES * page_size)} " \
            "a night on its own. `bin/rails railwatch:vacuum` returns all #{human(freelist * page_size)} now."
        else
          "\nNothing on the freelist: pruning is already returning this database's space as it goes."
        end
      end
    end

    # The whole point of asking explicitly, so this one is not bounded the way
    # the nightly prune is.
    def reclaim!
      with_telemetry do
        before = file_bytes
        if mode == :incremental
          Railwatch::TelemetryRecord.incremental_vacuum
        else
          puts "\nConverting to incremental auto-vacuum (full VACUUM, roughly #{estimate})..."
          connection.execute("PRAGMA auto_vacuum = incremental")
          connection.execute("VACUUM")
        end
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        "\nauto_vacuum=#{mode}, #{human(file_bytes)} on disk (#{human(before - file_bytes)} returned), #{freelist} pages left on the freelist."
      end
    end

    private
      def with_telemetry(&) = @environment.with_telemetry(&)

      def connection = Railwatch::TelemetryRecord.connection

      def mode = Railwatch::TelemetryRecord.auto_vacuum_mode

      def freelist = Railwatch::TelemetryRecord.freelist_pages

      def page_size = Railwatch::TelemetryRecord.page_size

      def path = Rails.root.join(Railwatch::TelemetryRecord.connection_db_config.database.to_s)

      def file_bytes = File.exist?(path) ? File.size(path) : 0

      def wal_bytes = File.exist?("#{path}-wal") ? File.size("#{path}-wal") : 0

      def estimate = ActiveSupport::Duration.build([ (file_bytes / VACUUM_BYTES_PER_SECOND.to_f).ceil, 1 ].max).inspect

      def human(bytes) = ActiveSupport::NumberHelper.number_to_human_size(bytes)
  end

  # Where this install's platform lives, derived from config.ingest_url:
  # railwatch:token and railwatch:mcp point at the same host the gem already
  # ships to, so a self-hosted app never gets told to visit railwatch.rebulk.com.
  class Endpoints
    HOSTED_HOST = "railwatch.rebulk.com"

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

namespace :railwatch do
  desc "Upload build source maps privately: railwatch:sourcemaps[directory,delete] (directory defaults to public; delete defaults to false)"
  task :sourcemaps, [ :directory, :delete ] => :environment do |_task, args|
    require "railwatch/source_maps"
    directory = args[:directory] || ENV["RAILWATCH_SOURCEMAPS_DIR"] || "public"
    delete = (args[:delete] || ENV["RAILWATCH_SOURCEMAPS_DELETE"]) == "true"
    count = Railwatch::SourceMaps.new(Railwatch.config).upload(directory: directory, delete: delete)
    puts "Uploaded #{count} source maps for #{Railwatch.config.deploy}#{' and deleted acknowledged files' if delete}"
  end

  desc "Check that the app can reach Railwatch with the configured token"
  task status: :environment do
    if Railwatch.config.local?
      puts "Railwatch OK: embedded (telemetry in this app's railwatch_telemetry database; dashboard at /railwatch)"
      next
    end
    unless Railwatch.config.token.present?
      abort "RAILWATCH_TOKEN is not set"
    end
    transport = Railwatch::Transport::Http.new(Railwatch.config)
    if transport.ping
      puts "Railwatch OK: #{Railwatch.config.ingest_url} (deploy=#{Railwatch.config.deploy || 'unset'}, server=#{Railwatch.config.server})"
    else
      abort "Railwatch unreachable at #{Railwatch.config.ingest_url}"
    end
  end

  desc "Check a Railwatch install end to end: token, ingest, middleware, routes, deploy, hooks, test helpers"
  task doctor: :environment do
    config = Railwatch.config
    blockers = []
    check = lambda do |ok, label, detail, fatal: false|
      puts "#{ok ? "✓" : "✗"} #{label}: #{detail}"
      blockers << label if !ok && fatal
      ok
    end

    if config.local?
      # Embedded: no token and no ingest host. What can go wrong instead is
      # the two databases the engine writes to and the jobs that derive
      # rollups and issues from them.
      check.call(true, "transport", "local (telemetry stays in this app; dashboard at the engine mount)")
      # Mirroring is opt-in, so silence means "not asked for". Asked for and
      # not working is the case worth failing on: the operator believes their
      # telemetry is leaving the box and it is not.
      if config.export_enabled
        problem = config.export_problem
        check.call(problem.nil?, "export", problem || "mirroring to #{config.resolved_export_url}", fatal: true)
        if problem.nil?
          status = Railwatch::Export::Outbox.new(config, Railwatch::Environment.current)
                                            .then { |outbox| Railwatch::Environment.current.with_telemetry { outbox.status } }
          check.call(status[:state] == "ready", "export destination",
                     status[:state] == "ready" ? "#{status[:queued_deliveries]} queued (#{status[:queued_bytes]} bytes), producer #{status[:producer_id]}" : "#{status[:state]}: #{status[:reason]} (bin/rails railwatch:export:rebind to clear)")
        end
      end
      %w[railwatch railwatch_telemetry].each do |name|
        configured = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: name)
        check.call(!configured.nil?, "#{name} database",
                   configured ? configured.database : "not in config/database.yml (bin/rails generate railwatch:install --local)",
                   fatal: true)
      end
      { "railwatch_telemetry" => Railwatch::TelemetryRecord, "railwatch" => Railwatch::ApplicationRecord }.each do |name, base|
        pending = begin
          base.connection_pool.migration_context.open.pending_migrations.map(&:version)
        rescue StandardError => e
          e.message
        end
        check.call(pending == [], "#{name} migrations",
                   case pending
                   when [] then "up to date"
                   when Array then "#{pending.size} pending (bin/rails db:prepare)"
                   else "cannot check: #{pending}"
                   end, fatal: true)
      end
      # The maintenance clock runs in web and worker processes, not in this
      # rake process, so what can be checked here is whether one has ticked.
      last_tick = begin
        Railwatch::MaintenanceTask.last_tick_at
      rescue StandardError
        nil
      end
      check.call(last_tick && last_tick > 10.minutes.ago, "maintenance",
                 if last_tick
                   "last tick #{ActiveSupport::Duration.build((Time.current - last_tick).round).inspect} ago"
                 else
                   "no tick recorded yet (runs inside the app's web and worker processes, not in rake)"
                 end)
      socket_path = config.writer_socket_path
      if socket_path && !Railwatch::Writer.usable_path?(socket_path)
        check.call(false, "writer process",
                   "socket path is #{socket_path.bytesize} bytes, over Linux's #{Railwatch::Writer::MAX_SOCKET_PATH}; " \
                   "set RAILWATCH_WRITER_SOCKET to a shorter path (e.g. /tmp/#{Rails.application.class.module_parent_name.parameterize}-railwatch.sock)")
      elsif socket_path
        listening = Railwatch::Writer.listening?(socket_path)
        puma_rb = Rails.root.join("config/puma.rb")
        plugged = puma_rb.exist? && puma_rb.read.include?("plugin :railwatch")
        # Not listening is only fine when the app is not running: this task
        # is its own process and cannot tell, so it says which case it is
        # looking at instead of calling a missing writer a pass.
        check.call(listening, "writer process",
                   if listening
                     "listening at #{socket_path}"
                   elsif plugged
                     "not listening at #{socket_path} right now. Expected if the app is stopped; if it is serving, " \
                     "the writer died or `plugin :railwatch` never activated (check the Puma log)"
                   else
                     "not configured: add `plugin :railwatch` to config/puma.rb so batches are written outside the " \
                     "processes serving requests"
                   end)
        # A socket that answers is a process that is alive; the ledger is
        # what says it is doing its job. Nothing written in a while with the
        # app serving traffic is a writer that is stuck or a worker that is
        # not reaching it.
        if listening
          last_write = begin
            Railwatch::Environment.current.with_telemetry { Railwatch::Telemetry::IngestBatch.maximum(:received_at) }
          rescue StandardError
            nil
          end
          check.call(last_write && last_write > 5.minutes.ago, "last write",
                     if last_write
                       "#{ActiveSupport::Duration.build((Time.current - last_write).round).inspect} ago"
                     else
                       "no batch written yet"
                     end)
        end
      end
      # HTTP Basic is on and closed until credentials exist; a deploy that
      # forgot gets a 401, not a public page, and this says so first.
      gate = config.dashboard_gate
      check.call(gate != :undeclared && !(gate == :basic && !config.http_basic_auth_configured?), "dashboard access",
                 case gate
                 when :basic
                   config.http_basic_auth_configured? ? "HTTP Basic, user #{config.http_basic_auth_user}" :
                     "closed: HTTP Basic is on with no credentials, so every dashboard request is 401. " \
                     "Run `bin/rails railwatch:authentication:configure`"
                 when :controller then "your own: c.base_controller_class = #{config.base_controller_class}"
                 when :resolver then "your own: c.dashboard_user decides, and live updates follow it"
                 when :open then "deliberately open: anyone who can reach the mount can read it (c.dashboard_open)"
                 else
                   "undeclared: HTTP Basic is off and no base_controller_class, dashboard_user or dashboard_open " \
                   "is set. If a routes constraint gates the mount, say so with `c.dashboard_open = true` " \
                   "(it also enables live updates); otherwise the dashboard is public"
                 end)
      check.call(!Railwatch::JsonCompat.broken?, "json compatibility",
                 Railwatch::JsonCompat.broken? ? Railwatch::JsonCompat.advice : "json #{Railwatch::JsonCompat.json_version} decodes on Rails #{Rails.version}")
      recurring = Rails.root.join("config/recurring.yml")
      leftover = recurring.exist? && recurring.read.include?("Railwatch::")
      check.call(!leftover, "recurring.yml",
                 leftover ? "Railwatch::* jobs listed in config/recurring.yml are no longer needed in embedded mode; remove them" : "no Railwatch entries (none needed)")
    else
    token = config.token.to_s
    check.call(!token.empty?, "token",
               token.empty? ? "RAILWATCH_TOKEN is not set" : Railwatch::SecretSafety.token_preview(token),
               fatal: true)

    exposed_token_files = Railwatch::SecretSafety.tracked_plaintext_token_files(root: Rails.root)
    check.call(exposed_token_files.empty?, "token storage",
               exposed_token_files.empty? ? "no tracked plaintext Railwatch token found" :
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
                 "plain HTTP refused; use HTTPS or set RAILWATCH_ALLOW_HTTP=true"
               end)

    check.call(Railwatch::Transport::Http.new(config).ping, "ingest reachable",
               "GET #{URI.join(config.ingest_url, '/ingest/ping')}", fatal: true)
    end

    middleware = Rails.application.middleware.map(&:name)
    position = middleware.index("Railwatch::Middleware::Request")
    check.call(!position.nil?, "request middleware",
               position ? "Railwatch::Middleware::Request at position #{position}" : "not in the middleware stack")

    mount = Rails.application.routes.routes.find { |r| r.app.respond_to?(:app) && r.app.app == Railwatch::Engine }
    beacon = Railwatch::Engine.routes.routes.any? { |r| r.defaults[:controller] == "railwatch/beacon" && r.defaults[:action] == "create" }
    check.call(!mount.nil? && beacon, "engine mounted",
               mount ? "POST #{mount.path.spec}/beacon -> railwatch/beacon#create" : %(add `mount Railwatch::Engine, at: "/railwatch"` to config/routes.rb))

    source = config.deploy_source
    if source == "config/initializers/railwatch.rb"
      detected_source = nil
      detected = Railwatch::ReleaseDetector.detect(project_root: Rails.root) { |found| detected_source = found }
      source = detected_source if detected == config.deploy
    end
    check.call(config.deploy.present?, "deploy",
               config.deploy.present? ? "#{config.deploy} (from #{source})" : "none: set RAILWATCH_DEPLOY")

    check.call(true, "sample rates", config.sample.map { |kind, rate| "#{kind}=#{rate}" }.join(" "))
    check.call(true, "ignored record types", config.ignore.empty? ? "none" : config.ignore.join(", "))

    check.call(true, "interactive sessions",
               "console=#{config.capture_console ? 'captured' : 'quiet'} " \
               "runner scratch paths=#{config.interactive_runner_paths.join(' ')} " \
               "(a typed/piped runner ships its command record, not its exception)")

    hook = Rails.root.join(".kamal/hooks/post-deploy")
    check.call(hook.exist? && hook.read.include?("railwatch"), "kamal post-deploy hook",
               hook.exist? ? hook.to_s : "not found (only needed when deploying with Kamal)")

    client = Rails.root.join("app/frontend/lib/railwatch.ts")
    check.call(client.exist?, "browser client",
               client.exist? ? "#{client} (call startRailwatch() from your Inertia entrypoint)" : "not found (only needed for Inertia visit timing)")

    # The client file existing is not the same as it running: startRailwatch()
    # has to be called from an entrypoint or no visit is ever timed.
    entrypoints = Dir[Rails.root.join("app/frontend/entrypoints/*")].select { |f| File.file?(f) }
    started = entrypoints.select { |f| File.read(f).include?("startRailwatch") }
    check.call(started.any?, "browser client imported",
               if started.any?
                 started.map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }.join(", ")
               elsif entrypoints.any?
                 "no entrypoint in app/frontend/entrypoints calls startRailwatch()"
               else
                 "no app/frontend/entrypoints (only needed for Inertia visit timing)"
               end)

    backend = Railwatch::Profiler.backend
    check.call(!backend.nil?, "profiler backend",
               backend || %(none -- add `gem "vernier"` (Ruby >= 3.2) or `gem "stackprof"` to profile slow executions))

    rails_helper = Rails.root.join("spec/rails_helper.rb")
    test_helper = Rails.root.join("test/test_helper.rb")
    wired = if rails_helper.exist? && rails_helper.read.include?("railwatch/rspec")
      %(spec/rails_helper.rb requires "railwatch/rspec")
    elsif test_helper.exist? && test_helper.read.include?("railwatch/minitest")
      %(test/test_helper.rb requires "railwatch/minitest")
    end
    check.call(!wired.nil?, "test matchers", wired || %(add `require "railwatch/rspec"` (or "railwatch/minitest") -- see docs/testing.md))

    abort "\nrailwatch:doctor failed: #{blockers.join(', ')}" if blockers.any?
    puts "\nRailwatch is wired up."
  end

  # Disk. `railwatch:vacuum:status` only reads; `railwatch:vacuum` is the
  # one-time conversion a database created before EnableIncrementalVacuum
  # needs, and it is a rake task rather than anything automatic because it
  # rewrites the whole file with the write lock held.
  desc "Report the telemetry database's size, free pages, and whether pruning can return them to the filesystem"
  task "vacuum:status" => :environment do
    disk = Railwatch::TelemetryDisk.open or next
    puts disk.report
    puts disk.advice
  end

  desc "Reclaim disk from the telemetry database. Converts it to incremental auto-vacuum if needed -- a full VACUUM, which locks the file"
  task vacuum: :environment do
    disk = Railwatch::TelemetryDisk.open or next
    puts disk.report
    puts disk.reclaim!
  end

  namespace :export do
    desc "Show what the export queue is holding and whether it can send"
    task status: :environment do
      env = Railwatch::Environment.current
      status = env.with_telemetry { Railwatch::Export::Outbox.new(Railwatch.config, env).status }
      status.each { |key, value| puts "#{key}: #{value}" }
    end

    desc "Clear a credential block, abandoning work admitted under the old token"
    task rebind: :environment do
      env = Railwatch::Environment.current
      discarded = env.with_telemetry { Railwatch::Export::Outbox.new(Railwatch.config, env).rebind! }
      puts discarded ? "rebound; #{discarded} queued deliveries abandoned" : "export is not configured"
    end

    desc "Abandon everything queued for export without contacting the receiver"
    task discard: :environment do
      env = Railwatch::Environment.current
      count = env.with_telemetry { Railwatch::Export::Outbox.new(Railwatch.config, env).discard_all! }
      puts "#{count} queued deliveries abandoned"
    end
  end

  desc "Print where to create an ingest token for this app's Railwatch platform"
  task token: :environment do
    base = Railwatch::Endpoints.new(Railwatch.config)
    puts <<~TEXT
      Railwatch platform: #{base.host_url}

      1. Sign in (or sign up) at #{base.url("/dashboard")}
      2. New application, then New environment (production, staging, ...)
      3. The environment's token (rw_...) is shown once, right after it is created.

      Then set it where this app reads its environment:

        RAILWATCH_TOKEN=rw_...#{"\n  RAILWATCH_INGEST_URL=#{base.host_url}" if base.self_hosted?}

      With Kamal:  bin/rails generate railwatch:install --prompt-token --kamal-secrets
      Verify:      bin/rails railwatch:doctor

      An existing environment's token can be rotated from its Settings page;
      the prefix shown in the UI is the first 12 characters of the token.
    TEXT
  end

  desc "Print ready-to-paste MCP client configuration for this app's Railwatch platform"
  task mcp: :environment do
    base = Railwatch::Endpoints.new(Railwatch.config)
    mcp = base.url("/mcp")
    token = "rwp_your_token_here"
    puts <<~TEXT
      Railwatch MCP server: #{mcp}

      An MCP token is per person, not per app: Settings -> Profile -> "API & MCP
      token" at #{base.url("/settings/profile")}. It starts with rwp_ and is
      shown once. Everything below is scoped to whatever accounts that user
      belongs to.

      Claude Code
        claude mcp add railwatch --transport http #{mcp} --header "Authorization: Bearer #{token}"

      Claude Desktop (claude_desktop_config.json) -- via the mcp-remote shim
        {
          "mcpServers": {
            "railwatch": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "#{mcp}", "--header", "Authorization: Bearer #{token}"]
            }
          }
        }

      Cursor (.cursor/mcp.json)
        {
          "mcpServers": {
            "railwatch": {
              "url": "#{mcp}",
              "headers": { "Authorization": "Bearer #{token}" }
            }
          }
        }

      VS Code (.vscode/mcp.json)
        {
          "servers": {
            "railwatch": {
              "type": "http",
              "url": "#{mcp}",
              "headers": { "Authorization": "Bearer #{token}" }
            }
          }
        }

      Zed (settings.json) -- via the mcp-remote shim
        {
          "context_servers": {
            "railwatch": {
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
      Railwatch's own docs at railwatch://docs/<name>. See docs/ai-and-mcp.md.
    TEXT
  end

  # The same shape as `mission_control:jobs:authentication:configure`: asks
  # for a user and password and writes them to the current environment's
  # credentials under `railwatch:`, which the engine reads at boot.
  #   RAILS_ENV=production bin/rails railwatch:authentication:configure
  desc "Configure HTTP Basic authentication for the embedded dashboard (writes Rails credentials)"
  task "authentication:configure" => :environment do
    Railwatch::Authentication.configure
  end

  desc "Send deploy metadata to Railwatch: rake railwatch:deploy[ref,name,url]"
  task :deploy, [ :ref, :name, :url ] => :environment do |_t, args|
    deploy = Railwatch.config.deploy or abort "RAILWATCH_DEPLOY (or KAMAL_VERSION) is not set"
    if Railwatch.config.local?
      # Embedded: the deploy marker is a row in this app's railwatch database.
      row = Railwatch::Environment.current.deploys.find_or_initialize_by(deploy: deploy.to_s.first(128))
      row.assign_attributes(ref: (args[:ref] || `git rev-parse HEAD 2>/dev/null`.strip).presence&.first(128),
                            name: args[:name].presence&.first(255), url: args[:url].presence&.first(1024),
                            server: Railwatch.config.server, deployed_at: Time.current,
                            commits: Railwatch::DeployMetadata.commits,
                            detail: { performer: ENV["KAMAL_PERFORMER"], destination: ENV["KAMAL_DESTINATION"],
                                      service: ENV["KAMAL_SERVICE"] }.compact)
      row.save!
      puts "Deploy #{deploy} recorded"
      next
    end
    abort "Plain HTTP ingest is disabled; use HTTPS or set RAILWATCH_ALLOW_HTTP=true" unless Railwatch.config.ingest_url_allowed?
    uri = URI.join(Railwatch.config.ingest_url, "/ingest/deploys")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{Railwatch.config.token}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(deploy: deploy, ref: args[:ref] || (`git rev-parse HEAD 2>/dev/null`.strip.presence),
                             name: args[:name], url: args[:url], server: Railwatch.config.server, timestamp: Time.now.utc.iso8601(6),
                             performer: ENV["KAMAL_PERFORMER"], destination: ENV["KAMAL_DESTINATION"],
                             service: ENV["KAMAL_SERVICE"], commits: Railwatch::DeployMetadata.commits)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
    res.is_a?(Net::HTTPSuccess) ? puts("Deploy #{deploy} recorded") : abort("Deploy failed: #{res.code} #{res.body}")
  end
end
