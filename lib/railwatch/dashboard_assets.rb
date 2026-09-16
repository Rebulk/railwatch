# frozen_string_literal: true

require "rack/files"

module Railwatch
  # Serves the prebuilt dashboard bundle the gem ships under public/railwatch.
  # Vite wrote every asset URL with base /railwatch/assets/, so a request for
  # /railwatch/assets/assets/app-abc123.js maps to public/railwatch/assets/
  # app-abc123.js. Files are content-hashed, so they are immutable.
  class DashboardAssets
    PREFIX = "/railwatch/assets/"

    def initialize(app, root:)
      @app = app
      @files = Rack::Files.new(root, {"cache-control" => "public, max-age=31536000, immutable"})
    end

    def call(env)
      path = env["PATH_INFO"]
      return @app.call(env) unless path.start_with?(PREFIX) && !path.include?("..")

      @files.call(env.merge("PATH_INFO" => path.delete_prefix("/railwatch/assets")))
    end
  end
end
