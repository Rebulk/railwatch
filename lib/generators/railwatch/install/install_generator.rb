# frozen_string_literal: true

require "rails/generators"
require "railwatch/secret_safety"

module Railwatch
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/railwatch.rb, a Kamal post-deploy hook, the browser client, and wires the test helpers. " \
           "With --local, also the two SQLite databases the in-app dashboard needs."

      class_option :local, type: :boolean, default: false,
                           desc: "Keep telemetry in this app and serve the dashboard at /railwatch: no token, no cloud."
      class_option :token, type: :string,
                           desc: "Deprecated: token in process arguments. Prefer --prompt-token, --token-stdin, or RAILWATCH_TOKEN."
      class_option :prompt_token, type: :boolean, default: false,
                                  desc: "Prompt for the ingest token without echoing it."
      class_option :token_stdin, type: :boolean, default: false,
                                 desc: "Read the ingest token from one line on standard input."
      class_option :url, type: :string,
                         desc: "Ingest URL, for a self-hosted Railwatch Cloud. Defaults to https://railwatch.rebulk.com."
      class_option :kamal_secrets, type: :boolean, default: false,
                                   desc: "Wire RAILWATCH_TOKEN through .kamal/secrets and config/deploy.yml's `env: secret:` list."
      class_option :doctor, type: :boolean, default: true,
                            desc: "Run railwatch:doctor when the install finishes."

      # Whichever of these exists is where `startRailwatch()` is added.
      INERTIA_ENTRYPOINTS = %w[
        app/frontend/entrypoints/inertia.tsx
        app/frontend/entrypoints/inertia.ts
        app/frontend/entrypoints/inertia.jsx
      ].freeze

      IMPORT_LINE = 'import { startRailwatch } from "@/lib/railwatch"'
      START_CALL = "startRailwatch()"

      # The name is written in three places -- .env, .kamal/secrets, and
      # config/deploy.yml -- and each of them has to be idempotent, so it is
      # spelled once here.
      TOKEN_VAR = "RAILWATCH_TOKEN"
      URL_VAR = "RAILWATCH_INGEST_URL"

      def create_initializer
        template "initializer.rb", "config/initializers/railwatch.rb"
      end

      # Two databases of its own, never the app's primary: `railwatch` for
      # what people author (issues, comments, saved views, thresholds) and
      # `railwatch_telemetry` for what the app reports, which is written
      # continuously and pruned. Their migrations live in the gem; the
      # database entries point migrations_paths at them, so db:prepare
      # creates the tables now and migrates them after every gem update.
      # Nothing is copied into the app.
      def configure_local_databases
        return unless options[:local]

        return say("--local: no config/database.yml found; add railwatch and railwatch_telemetry databases yourself (docs/embedded.md).", :yellow) unless File.exist?("config/database.yml")

        contents = File.read("config/database.yml")
        updated = self.class.database_yml_with_railwatch(contents)
        return say_status(:identical, "config/database.yml", :blue) if updated == contents

        create_file "config/database.yml", updated, force: true
      end

      # The writer process: one per Puma master, forked by the gem's Puma
      # plugin, so batches are mapped and written outside the web workers.
      def configure_local_writer
        return unless options[:local]
        return say("--local: no config/puma.rb found; add `plugin :railwatch` to your Puma config yourself (docs/embedded.md).", :yellow) unless File.exist?("config/puma.rb")

        contents = File.read("config/puma.rb")
        updated = self.class.puma_rb_with_railwatch(contents)
        return say_status(:identical, "config/puma.rb", :blue) if updated == contents

        create_file "config/puma.rb", updated, force: true
      end

      def create_kamal_hook
        return unless File.exist?("config/deploy.yml")
        template "post-deploy", ".kamal/hooks/post-deploy"
        chmod ".kamal/hooks/post-deploy", 0o755
      end

      def create_browser_client
        return unless File.directory?("app/frontend")
        template "railwatch.ts", "app/frontend/lib/railwatch.ts"
      end

      # Adds the import and the call to the Inertia entrypoint, so page-visit
      # timing and Core Web Vitals report with no further editing.
      def start_browser_client
        return unless File.directory?("app/frontend")

        path = INERTIA_ENTRYPOINTS.find { |candidate| File.exist?(candidate) }
        return say(browser_client_instructions(INERTIA_ENTRYPOINTS.first), :yellow) unless path

        contents = File.read(path)
        return say_status(:identical, path, :blue) if contents.include?(START_CALL)

        imports = contents.lines.select { |line| line.match?(/\A\s*import\s/) }
        return say(browser_client_instructions(path), :yellow) if imports.empty?

        # Anchored at \A so the injection lands after the *last* import line
        # and can only ever match once, however many imports repeat.
        inject_into_file path, "#{IMPORT_LINE}\n\n#{START_CALL}\n",
                         after: /\A[\s\S]*#{Regexp.escape(imports.last)}/
      end

      # `require "railwatch/rspec"` / `"railwatch/minitest"` brings in the block
      # matchers (have_railwatch_queries, have_railwatch_n_plus_one, ...) that turn
      # a spec suite into a performance gate. See docs/testing.md.
      def wire_test_helper
        if File.exist?("spec/rails_helper.rb")
          inject_require "spec/rails_helper.rb", 'require "railwatch/rspec"', %r{^require ["']rspec/rails["'].*\n}
        elsif File.exist?("test/test_helper.rb")
          inject_require "test/test_helper.rb", 'require "railwatch/minitest"', %r{^require ["']rails/test_help["'].*\n}
        end
      end

      def mount_beacon
        route 'mount Railwatch::Engine, at: "/railwatch"'
      end

      # A token lands in .env only when Git confirms the file is ignored.
      # URLs are not secret and can still be written to a tracked dotenv file.
      def write_env
        return if options[:local]

        token = resolved_token
        if options[:token]
          say("--token exposes #{Railwatch::SecretSafety.token_preview(options[:token])} in process arguments; " \
              "use --prompt-token or --token-stdin next time.", :yellow)
        end
        vars = { TOKEN_VAR => token, URL_VAR => options[:url] }.compact
        return if vars.empty?
        return say(env_instructions(vars), :yellow) unless dotenv_app?

        if token && !safe_dotenv_for_token?
          say("Refusing to write #{Railwatch::SecretSafety.token_preview(token)} to .env because Git does not confirm that .env is ignored. Use Rails credentials, a secret manager, or add .env to .gitignore first.", :red)
          vars.delete(TOKEN_VAR)
          return if vars.empty?
        end

        existing = File.exist?(".env") ? File.read(".env") : ""
        missing = vars.reject { |name, _| existing.match?(/^#{name}=/) }
        return say_status(:identical, ".env", :blue) if missing.empty?

        body = missing.map { |name, value| "#{name}=#{value}\n" }.join
        if File.exist?(".env")
          append_to_file ".env", (existing.end_with?("\n") || existing.empty? ? body : "\n#{body}")
        else
          create_file ".env", body
        end
      end

      # Kamal reads .kamal/secrets with shell expansion and passes only the
      # names listed under `env: secret:` into the container, so the token
      # needs both halves to reach the app.
      def configure_kamal_secrets
        return unless options[:kamal_secrets]
        return say("--kamal-secrets: no .kamal/secrets found; run `bin/kamal init` first.", :yellow) unless File.exist?(".kamal/secrets")

        secrets = File.read(".kamal/secrets")
        if secrets.match?(/^#{TOKEN_VAR}=/)
          say_status(:identical, ".kamal/secrets", :blue)
        else
          append_to_file ".kamal/secrets", "#{secrets.end_with?("\n") ? "" : "\n"}#{TOKEN_VAR}=$#{TOKEN_VAR}\n"
        end

        return say("--kamal-secrets: no config/deploy.yml found; add #{TOKEN_VAR} under `env: secret:` yourself.", :yellow) unless File.exist?("config/deploy.yml")

        deploy = File.read("config/deploy.yml")
        updated = self.class.deploy_yml_with_secret(deploy)
        return say_status(:identical, "config/deploy.yml", :blue) if updated == deploy

        create_file "config/deploy.yml", updated, force: true
      end

      def show_next_steps
        if options[:local]
          say <<~STEPS, :green

            Next steps
              1. Create the two databases:  bin/rails db:prepare
                 (after a future `bundle update railwatch`, the same command
                 migrates them)
              2. Restart the app and open /railwatch. Put the mount behind your
                 own authentication (a routes constraint or a controller check).
              3. Verify the install:  bin/rails railwatch:doctor
              4. Nothing else to run. With `plugin :railwatch` in config/puma.rb
                 (added if the file exists) Puma forks one Railwatch writer
                 process that writes every batch and runs the maintenance
                 clock, so no web worker ever holds the telemetry database.
                 No job worker needed.
          STEPS
          return
        end

        say <<~STEPS, :green

          Next steps
            1. Set #{TOKEN_VAR}. With Kamal, add it to .kamal/secrets:
                 #{TOKEN_VAR}=$#{TOKEN_VAR}
               and list it under `env: secret:` in config/deploy.yml (or re-run
               this generator with --kamal-secrets). Otherwise put it in
               credentials and read it in the initializer:
                 c.token = Rails.application.credentials.dig(:railwatch, :token)
               Self-hosting? Set #{URL_VAR} too.
               No token yet?  bin/rails railwatch:token
            2. Verify the install:  bin/rails railwatch:doctor
            3. Connect your AI assistant:  bin/rails railwatch:mcp
            4. Gate performance in CI: see docs/testing.md.
        STEPS
      end

      # Runs the same checklist the developer would run next, in this
      # process. Railwatch's configuration was read at boot, so a token this
      # run just wrote to .env is not visible until the app restarts -- the
      # note below says so rather than letting a ✗ look like a broken install.
      def run_doctor
        return unless options[:doctor]
        # The local install's databases do not exist until db:prepare, and this
        # process read its configuration before the initializer was written;
        # the doctor would only report both. The next steps say when to run it.
        return if options[:local]
        return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        say "\nbin/rails railwatch:doctor", :green
        require "rake"
        Rails.application.load_tasks unless Rake::Task.task_defined?("railwatch:doctor")
        Rake::Task["railwatch:doctor"].reenable
        Rake::Task["railwatch:doctor"].invoke
      rescue SystemExit
        say "\nFix the ✗ lines above and re-run `bin/rails railwatch:doctor`. " \
            "Values added to .env or credentials just now are only picked up after a restart.", :yellow
      rescue StandardError => e
        say "\nCould not run railwatch:doctor here (#{e.class}: #{e.message}). Run `bin/rails railwatch:doctor` yourself.", :yellow
      end

      # Adds RAILWATCH_TOKEN to config/deploy.yml's `env: secret:` list as a
      # targeted text insertion. A YAML round-trip would be shorter and would
      # throw away every comment in the file, which is most of what a Kamal
      # deploy.yml is. Returns the contents unchanged when it is already
      # listed.
      def self.deploy_yml_with_secret(contents, name = TOKEN_VAR)
        lines = contents.lines
        env_start = lines.index { |line| line.match?(/\Aenv:\s*(#.*)?$/) }
        return "#{contents.sub(/\n*\z/, "\n")}\nenv:\n  secret:\n    - #{name}\n" unless env_start

        env_end = block_end(lines, env_start)
        return contents if lines[env_start...env_end].any? { |line| line.match?(/\A\s*-\s*#{name}\s*\z/) }

        secret_start = (env_start + 1...env_end).find { |i| lines[i].match?(/\A\s+secret:\s*(#.*)?$/) }
        return insert_lines(lines, env_start + 1, "  secret:\n    - #{name}\n") unless secret_start

        insert_lines(lines, block_end(lines, secret_start), "    - #{name}\n")
      end

      RAILWATCH_DATABASES = <<~YAML
        railwatch:
          <<: *default
          database: storage/%<env>s_railwatch.sqlite3
          migrations_paths: <%%= Railwatch.migrations_path(:railwatch) %%>
          schema_dump: false
        railwatch_telemetry:
          <<: *default
          database: storage/%<env>s_railwatch_telemetry.sqlite3
          migrations_paths: <%%= Railwatch.migrations_path(:railwatch_telemetry) %%>
          schema_dump: false
          pragmas:
            journal_mode: wal
            synchronous: normal
            mmap_size: 134217728
            cache_size: -65536
            temp_store: memory
      YAML

      # Adds the railwatch and railwatch_telemetry databases to every
      # environment in config/database.yml. A flat environment
      # (`development:` straight to `<<: *default`) becomes a `primary:`
      # entry first, since named databases need the nested form. Text
      # insertion rather than a YAML round trip, for the same reason as
      # deploy_yml_with_secret: the comments are most of the file.
      def self.database_yml_with_railwatch(contents)
        lines = contents.lines
        %w[development test production].each do |env|
          start = lines.index { |line| line.match?(/\A#{env}:\s*(#.*)?$/) }
          next unless start

          stop = block_end(lines, start)
          block = lines[(start + 1)...stop]
          next if block.any? { |line| line.match?(/\A\s+railwatch_telemetry:\s*$/) }

          nested = block.any? { |line| line.match?(/\A  [a-z_]+:\s*$/) }
          unless nested
            lines[(start + 1)...stop] = block.map { |line| line.strip.empty? ? line : "  #{line}" }
            lines.insert(start + 1, "  primary:\n")
            stop += 1
          end
          entries = format(RAILWATCH_DATABASES, env: env).lines.map { |line| "  #{line}" }
          lines = insert_lines(lines, stop, entries.join).lines
        end
        lines.join
      end

      PUMA_PLUGIN_LINES = <<~RUBY

        # Railwatch (embedded): fork one writer process from the Puma master so
        # telemetry is mapped and written outside the web workers.
        plugin :railwatch if defined?(Railwatch)
      RUBY

      # Appends the plugin line once. Puma's config is plain Ruby evaluated top
      # to bottom, so the end of the file is always a valid place for it.
      def self.puma_rb_with_railwatch(contents)
        return contents if contents.include?("plugin :railwatch")

        "#{contents.sub(/\n*\z/, "\n")}#{PUMA_PLUGIN_LINES}"
      end

      # Index of the first line after the block opened at `start`: the next
      # line indented no more deeply than it, ignoring blanks and comments,
      # then backed up over any trailing blank lines so an insertion lands
      # inside the block rather than after the gap below it.
      def self.block_end(lines, start)
        indent = lines[start][/\A */].length
        stop = ((start + 1)...lines.length).find { |i|
          line = lines[i]
          next false if line.strip.empty? || line.strip.start_with?("#")
          line[/\A */].length <= indent
        } || lines.length
        stop -= 1 while stop > start + 1 && lines[stop - 1].strip.empty?
        stop
      end

      def self.insert_lines(lines, index, text)
        (lines[0...index] + [ text ] + lines[index..]).join
      end

      private_class_method :block_end, :insert_lines

      private

      def resolved_token
        @resolved_token ||= begin
          value = if options[:prompt_token]
            ask("Railwatch ingest token (input hidden):", echo: false)
          elsif options[:token_stdin]
            $stdin.gets
          elsif options[:token]
            options[:token]
          elsif !ENV[TOKEN_VAR].to_s.empty?
            ENV[TOKEN_VAR]
          end
          value = value.to_s.strip
          value unless value.empty?
        end
      end

      def safe_dotenv_for_token?
        !Railwatch::SecretSafety.git_tracked?(".env") && Railwatch::SecretSafety.git_ignored?(".env")
      end

      # dotenv is the only place the generator will write a token: an app
      # that keeps its environment anywhere else gets told what to paste.
      def dotenv_app?
        File.exist?(".env") || (File.exist?("Gemfile") && File.read("Gemfile").match?(/^\s*gem ["']dotenv/))
      end

      def env_instructions(vars)
        lines = vars.map do |name, value|
          if name == TOKEN_VAR
            "  #{name}=#{Railwatch::SecretSafety.token_preview(value)} (value hidden)"
          else
            "  #{name}=#{value}"
          end
        end
        "Set these where this app reads its environment (.kamal/secrets, credentials, or your PaaS config). " \
          "The token value is never printed:\n#{lines.join("\n")}"
      end

      def browser_client_instructions(path)
        "Add these two lines to #{path} to report Inertia visits and Core Web Vitals:\n" \
          "  #{IMPORT_LINE}\n  #{START_CALL}"
      end

      # inject_into_file on its own would append a second copy on a re-run --
      # Thor only skips when the replacement is already byte-identical in
      # place, and the anchor is not.
      def inject_require(path, line, anchor)
        contents = File.read(path)
        return say_status(:identical, path, :blue) if contents.include?(line)
        return say("Add `#{line}` to #{path} to get the Railwatch test matchers.", :yellow) unless contents.match?(anchor)

        inject_into_file path, "#{line}\n", after: anchor
      end
    end
  end
end
