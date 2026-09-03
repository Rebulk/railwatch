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

    # First application frame as "app/models/user.rb:12", or nil.
    def caller_location(skip: 2)
      locations = caller_locations(skip, 40) or return nil
      locations.each do |loc|
        path = loc.path
        next unless path.start_with?(app_root)
        next if path.include?("/lantern/")
        return "#{path.delete_prefix(app_root)}:#{loc.lineno}"
      end
      nil
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
