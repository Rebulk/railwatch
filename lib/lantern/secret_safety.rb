# frozen_string_literal: true

require "open3"

module Lantern
  # Read-only Git checks used by the installer and doctor. Tokens are never
  # returned in diagnostics: callers get a path or a short prefix only.
  module SecretSafety
    TOKEN_PATTERN = /\blt_[A-Za-z0-9_-]{6,}\b/
    TOKEN_FILE_GLOBS = [ ".env", ".env.*", ".kamal/secrets", "config/deploy.yml",
                         "config/initializers/*.rb" ].freeze

    module_function

    def token_preview(token)
      value = token.to_s
      return "unset" if value.empty?

      "#{value.byteslice(0, 6)}... (#{value.length} chars)"
    end

    def git_tracked?(path, root: Dir.pwd)
      _output, status = git(root, "ls-files", "--error-unmatch", "--", path)
      status.success?
    end

    def git_ignored?(path, root: Dir.pwd)
      _output, status = git(root, "check-ignore", "-q", "--", path)
      status.success?
    end

    def tracked_plaintext_token_files(root: Dir.pwd)
      output, status = git(root, "ls-files", "-z", "--", *TOKEN_FILE_GLOBS)
      return [] unless status.success?

      output.split("\0").filter_map do |relative|
        next if relative.empty?

        path = File.join(root.to_s, relative)
        next unless File.file?(path) && !File.symlink?(path)
        next unless File.binread(path).match?(TOKEN_PATTERN)

        relative
      rescue SystemCallError
        nil
      end
    end

    def git(root, *arguments)
      output, _error, status = Open3.capture3("git", "-C", root.to_s, *arguments)
      [ output, status ]
    rescue SystemCallError
      [ "", NullStatus.new ]
    end
    private_class_method :git

    class NullStatus
      def success? = false
    end
    private_constant :NullStatus
  end
end
