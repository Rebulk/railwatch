# frozen_string_literal: true

module Railwatch
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
    # The gem's own lib/ directory, so frames inside Railwatch are skipped by
    # prefix rather than by a substring that would also match any app whose
    # checkout happens to live under a folder named "railwatch" (including
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
    # etc). Railwatch itself is excluded separately via gem_root because in
    # this repo's own test suite (and in a `path:`/`git:` Gemfile checkout)
    # it is loaded straight from a working tree, not from a Gem.path install.
    def installed_gem_path?(path)
      Gem.path.any? { |p| path.start_with?("#{p}/") }
    end

    # One line of a String backtrace: "path:line:in 'label'" (Ruby 3.4),
    # "path:line:in `label'" (earlier), or a bare "path:line".
    BACKTRACE_LINE = /\A(.+?):(\d+)(?::in [`'](.*)')?\z/

    def frames(exception, with_source: true, limit: 50)
      raw_frames(exception, limit).map do |path, lineno, label|
        in_app = path.to_s.start_with?(app_root)
        frame = {
          file: in_app ? path.delete_prefix(app_root) : path,
          line: lineno,
          function: label,
          in_app: in_app
        }
        frame[:code] = source_snippet(path, lineno) if with_source && in_app
        frame
      end
    end

    # [path, line, label] per frame. backtrace_locations is nil for any
    # exception whose backtrace was assigned rather than raised into it --
    # ActiveRecord::StatementInvalid (set_backtrace from the driver error),
    # Faraday::Error (delegates #backtrace to the wrapped exception) -- which
    # are the most common production exceptions, so fall back to parsing the
    # strings rather than shipping them with no frames, no culprit, and a
    # fingerprint of nothing but class and message.
    def raw_frames(exception, limit)
      locations = exception.backtrace_locations
      if locations
        locations.first(limit).map { |loc| [ loc.absolute_path || loc.path, loc.lineno, loc.label ] }
      else
        Array(exception.backtrace).first(limit).filter_map do |line|
          match = BACKTRACE_LINE.match(line.to_s) or next
          [ match[1], match[2].to_i, match[3] ]
        end
      end
    end

    # --- Browser stacks ---------------------------------------------------

    # One frame of a JavaScript stack, in either of the two shapes engines
    # write: V8's "at fn (https://host/assets/app-abc.js:1:2)" (and the same
    # line without the function name), or SpiderMonkey and JavaScriptCore's
    # "fn@https://host/assets/app-abc.js:1:2". A line with no file:line on it
    # -- V8's leading "TypeError: ..." header, "at new Promise (<anonymous>)"
    # -- matches neither and is dropped.
    JS_FRAME = /
      \A
      (?:at\s+)?                       # V8 indents every frame with "at "
      (?:(?<function>[^@]*?)\s*[@(])?  # "fn@" (Firefox, Safari) or "fn (" (V8)
      (?<file>\S+?)
      :(?<line>\d+)(?::(?<column>\d+))? # line and column (both one-based)
      \)?
      \z
    /x

    # Frames from the app's own origin that are still not the app's code.
    VENDOR_PATH = %r{(?:\A|/)(?:node_modules|vendor)\b}

    MAX_JS_FRAMES = 50

    # A browser stack, exactly as the engine wrote it, in the same frame
    # shape as a Ruby backtrace. `origin` is the app's own scheme and host: a
    # script served from it is the app's own, so its file is stored relative
    # to that origin the way a Ruby frame is stored relative to Rails.root,
    # and anything from a CDN, an extension, or a third-party tag keeps its
    # whole URL and is not in_app.
    def js_frames(stack, origin: nil, limit: MAX_JS_FRAMES)
      frames = []
      stack.to_s.each_line do |raw|
        break if frames.size >= limit
        match = JS_FRAME.match(raw.strip) or next
        url = match[:file].split("?", 2).first.to_s
        own = js_own_origin?(url, origin)
        file = own ? url.delete_prefix(origin.to_s).delete_prefix("/") : url
        function = match[:function].to_s.strip
        frame = {
          file: file[0, 255],
          line: match[:line].to_i,
          function: function.empty? ? "(anonymous)" : function[0, 255],
          in_app: own && !VENDOR_PATH.match?(file)
        }
        frame[:column] = match[:column].to_i if match[:column]
        frames << frame
      end
      frames
    end

    # A bare path ("/assets/app.js") can only be the app's own; an absolute
    # URL is only the app's own when it is on the app's origin.
    def js_own_origin?(url, origin)
      return true if url.start_with?("/")
      return false if origin.nil? || origin.empty?
      url.start_with?("#{origin}/")
    end

    MAX_SOURCE_BYTES = 1024 * 1024

    def source_snippet(path, line, context: 5)
      return nil unless path
      # String backtraces can be assigned by libraries. A lexical Rails.root
      # prefix alone allows ../ and symlinks to disclose files outside it.
      root = File.realpath(app_root) + File::SEPARATOR
      source = File.realpath(path)
      return nil unless source.start_with?(root) && File.file?(source)

      data = File.binread(source, MAX_SOURCE_BYTES + 1)
      return nil if data.bytesize > MAX_SOURCE_BYTES
      lines = data.force_encoding(Encoding::UTF_8).scrub.lines(chomp: true)
      from = [ line - context - 1, 0 ].max
      to = [ line + context - 1, lines.size - 1 ].min
      (from..to).to_h { |i| [ i + 1, lines[i].to_s[0, 200] ] }
    rescue StandardError
      nil
    end
  end
end
