# frozen_string_literal: true

require "net/http"
require "uri"
require "pathname"
require "json"

module Lantern
  # Upload locally built source maps to private telemetry storage. This runs
  # during release preparation; it never follows map URLs or HTTP redirects.
  class SourceMaps
    MAX_BYTES = 10 * 1024 * 1024

    def initialize(config)
      @config = config
    end

    def upload(directory: "public", delete: false)
      raise ArgumentError, "LANTERN_TOKEN is not set" if @config.token.to_s.empty?
      raise ArgumentError, "LANTERN_DEPLOY (or KAMAL_VERSION) is not set" if @config.deploy.to_s.empty?
      raise ArgumentError, "plain HTTP ingest is disabled; use HTTPS or set LANTERN_ALLOW_HTTP=true" unless @config.ingest_url_allowed?
      root = Pathname.new(directory).realpath
      files = Dir[root.join("**/*.map").to_s].sort.select { |path| File.file?(path) }
      raise ArgumentError, "no .map files found in #{root}" if files.empty?
      files.each do |path|
        file = Pathname.new(path)
        unless file.realpath.to_s.start_with?(root.to_s + File::SEPARATOR) && !file.symlink?
          raise ArgumentError, "source map must be a regular file within the upload directory"
        end
        data = File.binread(file, MAX_BYTES + 1)
        raise ArgumentError, "source map exceeds 10 MiB: #{file.basename}" if data.bytesize > MAX_BYTES
        filename = file.relative_path_from(root).to_s.delete_suffix(".map")
        upload_file(filename, data)
        File.delete(file) if delete
      end
      files.size
    end

    private

    def upload_file(filename, data)
      uri = URI.join(@config.ingest_url, "/ingest/sourcemaps")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@config.token}"
      request["Content-Type"] = "application/octet-stream"
      request["X-Lantern-Deploy"] = @config.deploy
      request["X-Lantern-Filename"] = filename
      request.body = data
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30, write_timeout: 30) { |http| http.request(request) }
      unless response.is_a?(Net::HTTPSuccess)
        raise "Source map upload failed (HTTP #{response.code}) for #{filename}"
      end
      result = JSON.parse(response.body)
      unless result["ok"] == true && result["filename"] == filename && result["bytes"] == data.bytesize
        raise "Source map upload was not acknowledged for #{filename}"
      end
    end
  end
end
