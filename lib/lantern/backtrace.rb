# frozen_string_literal: true

module Lantern
  # Locates the app frame that caused a query or outgoing request, and
  # serialises exception frames with source snippets for app code.
  module Backtrace
    module_function

    def app_root
      @app_root ||= (defined?(Rails) && Rails.root ? Rails.root.to_s + "/" : Dir.pwd + "/")
    end

    def clean(frames)
      cleaner = defined?(Rails) && Rails.respond_to?(:backtrace_cleaner) ? Rails.backtrace_cleaner : nil
      cleaner ? cleaner.clean(frames) : frames
    end

    # First application frame as "app/models/user.rb:12", or nil. 100 frames
    # clears framework internals in practice (Rails 8.1's instrumentation and
    # query-cache wrapping alone run 40+ frames deep before reaching app code,
    # more once a view template is on the stack) and keeps the walk (and the
    # array it allocates) cheap on the hot query path.
    # The gem's own lib/ directory, so frames inside Lantern are skipped by
    # prefix rather than by a substring that would also match any app whose
    # checkout happens to live under a folder named "lantern" (including
    # this repo's own spec/dummy, which lives under the repo root but not
    # under its lib/).
    GEM_ROOT = File.expand_path("..", __dir__) + "/"

    def gem_root
      GEM_ROOT
    end

    def caller_location(skip: 2)
      locations = caller_locations(skip, 100) or return nil
      locations.each do |loc|
        path = loc.path
        next if path.start_with?(gem_root)
        next if installed_gem_path?(path)
        return "#{path.delete_prefix(app_root)}:#{loc.lineno}"
      end
      nil
    end

    # True for frames inside an installed gem (net-http, webmock, rspec-core,
    # etc). Lantern itself is excluded separately via gem_root because in
    # this repo's own test suite (and in a `path:`/`git:` Gemfile checkout)
    # it is loaded straight from a working tree, not from a Gem.path install.
    def installed_gem_path?(path)
      Gem.path.any? { |p| path.start_with?("#{p}/") }
    end

    def frames(exception, with_source: true, limit: 50)
      Array(exception.backtrace_locations || []).first(limit).map do |loc|
        path = loc.absolute_path || loc.path
        in_app = path.to_s.start_with?(app_root)
        frame = {
          file: in_app ? path.delete_prefix(app_root) : path,
          line: loc.lineno,
          function: loc.label,
          in_app: in_app
        }
        frame[:code] = source_snippet(path, loc.lineno) if with_source && in_app
        frame
      end
    end

    def source_snippet(path, line, context: 5)
      return nil unless path && File.readable?(path)
      lines = File.readlines(path, chomp: true)
      from = [ line - context - 1, 0 ].max
      to = [ line + context - 1, lines.size - 1 ].min
      (from..to).to_h { |i| [ i + 1, lines[i].to_s[0, 200] ] }
    rescue StandardError
      nil
    end
  end
end
