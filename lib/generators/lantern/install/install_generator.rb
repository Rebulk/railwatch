# frozen_string_literal: true

require "rails/generators"

module Lantern
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/lantern.rb, a Kamal post-deploy hook, the browser client, and wires the test helpers."

      # Whichever of these exists is where `startLantern()` is added.
      INERTIA_ENTRYPOINTS = %w[
        app/frontend/entrypoints/inertia.tsx
        app/frontend/entrypoints/inertia.ts
        app/frontend/entrypoints/inertia.jsx
      ].freeze

      IMPORT_LINE = 'import { startLantern } from "@/lib/lantern"'
      START_CALL = "startLantern()"

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

      def show_next_steps
        say <<~STEPS, :green

          Next steps
            1. Set LANTERN_TOKEN. With Kamal, add it to .kamal/secrets:
                 LANTERN_TOKEN=$LANTERN_TOKEN
               and list it under `env: secret:` in config/deploy.yml. Otherwise
               put it in credentials and read it in the initializer:
                 c.token = Rails.application.credentials.dig(:lantern, :token)
               Self-hosting? Set LANTERN_INGEST_URL too.
            2. Verify the install:  bin/rails lantern:doctor
            3. Gate performance in CI: see docs/testing.md.
        STEPS
      end

      private

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
