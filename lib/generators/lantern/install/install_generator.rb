# frozen_string_literal: true

require "rails/generators"

module Lantern
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/lantern.rb, a Kamal post-deploy hook, and the browser client."

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
        say "Import and call `startLantern()` from app/frontend/entrypoints/inertia.tsx to report Inertia visit timings.", :green
      end

      def mount_beacon
        route 'mount Lantern::Engine, at: "/lantern"'
      end

      def show_next_steps
        say "\nSet LANTERN_TOKEN (and LANTERN_INGEST_URL if self-hosting), then run: bin/rails lantern:status", :green
      end
    end
  end
end
