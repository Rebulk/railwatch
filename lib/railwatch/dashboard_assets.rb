# frozen_string_literal: true

require "rack/files"

module Railwatch
  # Serves the prebuilt dashboard bundle the gem ships under public/railwatch.
  # Vite wrote every asset URL with base /railwatch/assets/, so a request for
  # /railwatch/assets/assets/app-abc123.js maps to public/railwatch/assets/
  # app-abc123.js. Files are content-hashed, so they are immutable. The
  # favicon is the one unhashed file, served with a short cache instead.
  class DashboardAssets
    PREFIX = "/railwatch/assets/"
    ICONS = { "/railwatch/icon.svg" => "/icon.svg", "/railwatch/icon.png" => "/icon.png" }.freeze

    # Put this middleware in the host's stack. Before ActionDispatch::Static
    # when the host has it, which is what keeps a same-named file in the
    # app's own public/ from shadowing the dashboard's. An app that serves
    # static files from nginx, a CDN or Thruster sets
    # `config.public_file_server.enabled = false` and has no such middleware:
    # inserting relative to it would raise and take the whole application
    # down at boot, so go to the front instead, which is the same position
    # relative to everything that remains.
    def self.install!(app, root:)
      if app.config.public_file_server.enabled
        app.middleware.insert_before ActionDispatch::Static, self, root: root
      else
        app.middleware.insert 0, self, root: root
      end
    end

    def initialize(app, root:)
      @app = app
      @files = Rack::Files.new(root, { "cache-control" => "public, max-age=31536000, immutable" })
      @icons = Rack::Files.new(root, { "cache-control" => "public, max-age=86400" })
    end

    def call(env)
      path = env["PATH_INFO"]
      return @icons.call(env.merge("PATH_INFO" => ICONS[path])) if ICONS.key?(path)
      return @app.call(env) unless path.start_with?(PREFIX) && !path.include?("..")

      @files.call(env.merge("PATH_INFO" => path.delete_prefix("/railwatch/assets")))
    end
  end
end
