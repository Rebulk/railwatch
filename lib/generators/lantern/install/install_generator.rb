# frozen_string_literal: true

require "rails/generators"

module Lantern
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/lantern.rb, a Kamal post-deploy hook, the browser client, and wires the test helpers."

      class_option :token, type: :string,
                           desc: "Ingest token for this environment (lt_...). Written to .env, or printed with where to put it."
      class_option :url, type: :string,
                         desc: "Ingest URL, for a self-hosted Lantern Cloud. Defaults to https://lantern.rebulk.com."
      class_option :kamal_secrets, type: :boolean, default: false,
                                   desc: "Wire LANTERN_TOKEN through .kamal/secrets and config/deploy.yml's `env: secret:` list."
      class_option :doctor, type: :boolean, default: true,
                            desc: "Run lantern:doctor when the install finishes."

      # Whichever of these exists is where `startLantern()` is added.
      INERTIA_ENTRYPOINTS = %w[
        app/frontend/entrypoints/inertia.tsx
        app/frontend/entrypoints/inertia.ts
        app/frontend/entrypoints/inertia.jsx
      ].freeze

      IMPORT_LINE = 'import { startLantern } from "@/lib/lantern"'
      START_CALL = "startLantern()"

      # The name is written in three places -- .env, .kamal/secrets, and
      # config/deploy.yml -- and each of them has to be idempotent, so it is
      # spelled once here.
      TOKEN_VAR = "LANTERN_TOKEN"
      URL_VAR = "LANTERN_INGEST_URL"

      def create_initializer
        template "initializer.rb", "config/initializers/lantern.rb"
      end

      def create_kamal_hook
        return unless File.exist?("config/deploy.yml")
        template "post-deploy", ".kamal/hooks/post-deploy"
        chmod ".kamal/hooks/post-deploy", 0o755
      end

      def create_browser_client
        return unless File.directory?("app/frontend")
        template "lantern.ts", "app/frontend/lib/lantern.ts"
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

      # `require "lantern/rspec"` / `"lantern/minitest"` brings in the block
      # matchers (have_lantern_queries, have_lantern_n_plus_one, ...) that turn
      # a spec suite into a performance gate. See docs/testing.md.
      def wire_test_helper
        if File.exist?("spec/rails_helper.rb")
          inject_require "spec/rails_helper.rb", 'require "lantern/rspec"', %r{^require ["']rspec/rails["'].*\n}
        elsif File.exist?("test/test_helper.rb")
          inject_require "test/test_helper.rb", 'require "lantern/minitest"', %r{^require ["']rails/test_help["'].*\n}
        end
      end

      def mount_beacon
        route 'mount Lantern::Engine, at: "/lantern"'
      end

      # --token/--url land in .env when the app already keeps its environment
      # there (a .env file, or dotenv in the Gemfile). Anywhere else -- Kamal
      # secrets, credentials, a PaaS config UI -- there is no file to edit
      # safely, so the values are printed with the exact lines to paste.
      def write_env
        vars = { TOKEN_VAR => options[:token], URL_VAR => options[:url] }.compact
        return if vars.empty?
        return say(env_instructions(vars), :yellow) unless dotenv_app?

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
        say <<~STEPS, :green

          Next steps
            1. Set #{TOKEN_VAR}. With Kamal, add it to .kamal/secrets:
                 #{TOKEN_VAR}=$#{TOKEN_VAR}
               and list it under `env: secret:` in config/deploy.yml (or re-run
               this generator with --kamal-secrets). Otherwise put it in
               credentials and read it in the initializer:
                 c.token = Rails.application.credentials.dig(:lantern, :token)
               Self-hosting? Set #{URL_VAR} too.
               No token yet?  bin/rails lantern:token
            2. Verify the install:  bin/rails lantern:doctor
            3. Connect your AI assistant:  bin/rails lantern:mcp
            4. Gate performance in CI: see docs/testing.md.
        STEPS
      end

      # Runs the same checklist the developer would run next, in this
      # process. Lantern's configuration was read at boot, so a token this
      # run just wrote to .env is not visible until the app restarts -- the
      # note below says so rather than letting a ✗ look like a broken install.
      def run_doctor
        return unless options[:doctor]
        return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        say "\nbin/rails lantern:doctor", :green
        require "rake"
        Rails.application.load_tasks unless Rake::Task.task_defined?("lantern:doctor")
        Rake::Task["lantern:doctor"].reenable
        Rake::Task["lantern:doctor"].invoke
      rescue SystemExit
        say "\nFix the ✗ lines above and re-run `bin/rails lantern:doctor`. " \
            "Values added to .env or credentials just now are only picked up after a restart.", :yellow
      rescue StandardError => e
        say "\nCould not run lantern:doctor here (#{e.class}: #{e.message}). Run `bin/rails lantern:doctor` yourself.", :yellow
      end

      # Adds LANTERN_TOKEN to config/deploy.yml's `env: secret:` list as a
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

      # dotenv is the only place the generator will write a token: an app
      # that keeps its environment anywhere else gets told what to paste.
      def dotenv_app?
        File.exist?(".env") || (File.exist?("Gemfile") && File.read("Gemfile").match?(/^\s*gem ["']dotenv/))
      end

      def env_instructions(vars)
        "Set these where this app reads its environment (.kamal/secrets, credentials, or your PaaS config):\n" +
          vars.map { |name, value| "  #{name}=#{value}" }.join("\n")
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
        return say("Add `#{line}` to #{path} to get the Lantern test matchers.", :yellow) unless contents.match?(anchor)

        inject_into_file path, "#{line}\n", after: anchor
      end
    end
  end
end
