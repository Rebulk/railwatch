# frozen_string_literal: true

module Railwatch
  # Header and parameter redaction. Parameter redaction reuses the app's own
  # Rails.application.config.filter_parameters plus Railwatch's list, so
  # anything the app already hides from logs is hidden here too.
  class Redactor
    FILTERED = "[FILTERED]"
    # Credentials are often carried in vendor-specific headers that an app
    # cannot enumerate ahead of time (X-Api-Key, Stripe-Signature,
    # X-Auth-Token, and similar). Match credential-shaped name segments in
    # addition to the exact configurable denylist. Identity headers an
    # authenticating proxy adds (X-Forwarded-Email, X-Remote-User, a client
    # certificate) name a person, so they count too.
    SENSITIVE_HEADER_NAME = %r{
      (?:\A|-)
      (?:
        api-?(?:key|token|secret)|access-?(?:key|token|secret)|
        private-?(?:key|token)|secret-?key|signing-?key|encryption-?key|
        auth(?:entication|orization)?(?:-?token)?|bearer(?:-?token)?|
        client-?(?:secret|token)|session-?token|refresh-?token|
        security-?token|service-?token|identity-?token|id-?token|
        csrf-?token|xsrf-?token|credential|
        hmac(?:-?signature)?|jwt(?:-?(?:assertion|token))?|
        webhook-?(?:hmac|secret|signature)|token|secret|signature|
        password|passwd|session-?id|subscription-?key|client-?cert|
        (?:forwarded|remote)-?(?:user|email)|
        oidc|client-?principal|dpop|(?:user-?)?email|preferred-?username|session
      )
      (?:-|\z)
    }ix
    # The browser client's own session header: its value is the record's
    # session_id, a random id for grouping visits, not a credential.
    OWN_HEADERS = %w[x-railwatch-session].to_set.freeze
    # A dynamic route segment with one of these in its name carries a
    # credential: Rails 8's `resources :passwords, param: :token`, invite,
    # magic-link and confirmation routes. So does one the app's own
    # filter_parameters (or redact_params) names.
    SENSITIVE_PATH_PARAMETER = /token|secret|key|code|signature|password/i
    ROUTING_PATH_PARAMETERS = %i[controller action format].freeze
    NO_SECRETS = [].freeze
    # #scrub: nesting followed before a container is elided, which bounds the
    # walk; entries read from one container, which is past anything a
    # 200-character #inspect shows; and values visited in all, across every
    # branch, so a structure holding the same container many times over is
    # not walked once per path to it. A container already on the path to
    # itself is elided at once.
    SCRUB_MAX_DEPTH = 5
    SCRUB_MAX_ENTRIES = 100
    SCRUB_MAX_NODES = 1_000
    SCRUB_ELIDED = Object.new.tap { |elided| def elided.inspect = "…" }.freeze
    # #scrub's key for a value stored under no name at all: the root, or an
    # element of an Array at the root. No filter looks at it.
    SCRUB_NO_KEY = Object.new.freeze
    URL_ORIGIN = %r{\A(?:[A-Za-z][A-Za-z0-9+.-]*:)?//[^/]*}

    def initialize(config)
      @config = config
      @header_keys = config.redact_headers.map { |h| h.downcase }.to_set
      @param_filter = nil
    end

    # The values of a matched route's sensitive dynamic segments.
    def path_secrets(path_parameters)
      return NO_SECRETS if path_parameters.nil? || path_parameters.empty?

      secrets = nil
      path_parameters.each do |name, value|
        next unless value.is_a?(String) && !value.empty?
        next if ROUTING_PATH_PARAMETERS.include?(name.to_sym)
        next unless sensitive_path_parameter?(name.to_s)

        (secrets ||= []) << value
      end
      secrets || NO_SECRETS
    end

    # path (or a URL) with each segment that holds one of secrets replaced
    # by [FILTERED]. A segment is compared unescaped, so any percent-encoding
    # of the value matches; "<secret>.json" keeps its format. A glob value
    # spans segments and is replaced where it appears whole, however its
    # characters (slashes included) are encoded. A value no segment holds
    # whole sits beside literal text (/reset/prefix-:token): every segment
    # that contains it is replaced.
    def filter_path(path, secrets)
      return path if secrets.empty? || path.nil?

      path = path.to_s
      # A URL's scheme and authority are not the route's: only its path is
      # compared.
      origin = path[URL_ORIGIN].to_s
      path = path[origin.length..]
      secrets.each { |secret| path = filter_glob(path, secret) if secret.include?("/") }
      segments = path.split("/", -1)
      secrets.each do |secret|
        next if secret.include?("/")

        # Whole segments first, then a capture beside literal text in its
        # segment. Both, always: a secret equal to a literal word of the
        # route (/reset/prefix-:token with token "reset") must not let the
        # literal's match stand in for the capture's.
        segments.map! { |segment| filter_segment(segment, secret) }
        segments.map! { |segment| unescape(segment).include?(secret) ? FILTERED : segment }
      end
      origin + segments.join("/")
    end

    # A URL of this app (a redirect target, a Referer, a page the browser
    # reports) with the sensitive segments of the route it names filtered.
    # Only a path on this app: an absolute URL on another host is left as
    # it is (pass the request's host as host). url is expected already
    # cleaned of query, fragment and userinfo.
    def filter_url(url, host: nil, method: "GET")
      return url if url.nil? || url.empty?

      url = url.to_s
      path = if url.start_with?("/") && !url.start_with?("//")
        url
      elsif host && (uri = URI.parse(url)).host&.casecmp?(host.to_s)
        uri.path
      end
      return url if path.nil? || path.empty?

      filter_path(url, url_secrets(path, method: method, host: host))
    rescue StandardError
      url
    end

    # The values of the sensitive segments of the route path names. Nothing
    # tells us which route a URL is, so the app's router is asked -- but
    # only when the path has the shape of a route with a sensitive segment
    # (sensitive_routes): every other URL costs a few regexp matches, not a
    # route recognition. When the router recognises none for method (a
    # mounted Rack app, a verb the route does not take), the shape decides,
    # and the segment is filtered. The path is normalised the way the router
    # does it first (a trailing slash, doubled slashes), and recognised on
    # host when given, so a route constrained to a host is the one picked
    # for a URL on that host.
    def url_secrets(path, method: "GET", host: nil)
      path = ActionDispatch::Journey::Router::Utils.normalize_path(path) if defined?(ActionDispatch::Journey::Router::Utils)
      shaped = shaped_secrets(path, sensitive_routes)
      return shaped if shaped.empty? || !defined?(Rails) || !Rails.application

      begin
        params = Rails.application.routes.recognize_path(host ? "http://#{host}#{path}" : path, method: method)
      rescue StandardError
        return shaped
      end
      path_secrets(params)
    end

    # A page URL a browser reported (a Referer, a beacon's visit): without
    # fragment and userinfo, without its query unless the app opted in
    # (config.capture_browser_query_strings), and with its route's
    # sensitive segments filtered. Cleaned whole, cut to limit after: cut
    # first, a long userinfo loses its "@" and survives.
    def browser_url(url, limit:, host: nil, method: "GET")
      url = url.to_s
      query = nil
      if @config.capture_browser_query_strings
        url = url[0, url.index("#")] if url.include?("#")
        url, query = url.split("?", 2)
        url = url.to_s
      end
      clean = filter_url(Record.url_without_sensitive_components(url, limit: url.length), host: host, method: method)
      (query ? "#{clean}?#{query}" : clean)[0, limit]
    end

    def headers(hash)
      hash.each_with_object({}) do |(k, v), out|
        out[k] = redact_header?(k) ? FILTERED : v.to_s[0, 512]
      end
    end

    # Header names arrive already capitalised ("Authorization"); the lookup
    # set is lower-case, so cache the downcased form per distinct name.
    def redact_header?(name)
      @header_case ||= {}
      hit = @header_case[name]
      return hit unless hit.nil?
      @header_case.clear if @header_case.size > 512
      normalized = name.to_s.downcase
      @header_case[name] = @header_keys.include?(normalized) || (!OWN_HEADERS.include?(normalized) && SENSITIVE_HEADER_NAME.match?(normalized))
    end

    def params(hash)
      param_filter.filter(hash)
    rescue StandardError
      {}
    end

    # For a value about to be turned into ONE string with #inspect (an
    # exception local, a span attribute): a copy with every value under a
    # filtered key masked. #params can only filter by the name the string is
    # stored under, so `attrs = { password: ... }` needs its keys looked at
    # while it still has them. Anything that is not a Hash, an Array or a
    # params object comes back as it is. It runs while an exception is being
    # reported, so it must end, and soon, whatever it is given.
    def scrub(value)
      scrub_value(value, 0, [], [ SCRUB_MAX_NODES ])
    end

    private

    # path: the containers from the root down to value, compared by
    # identity. budget: one count of values left, shared by the whole walk.
    # key and key_path: the name value is stored under and the dotted names
    # leading to it ("billing.number"), the way the app's parameter filter
    # would see them; SCRUB_NO_KEY for a value stored under no name. parent:
    # [the Hash that key is in, its copy for a Proc filter once made]. A
    # params object is read from its own store: #to_unsafe_h converts all of
    # it, with no limit, first, and #each_pair converts each nested Array
    # whole, so either overflows the stack on one that holds itself (a
    # SystemStackError, which no `rescue StandardError` stops).
    def scrub_value(value, depth, path, budget, key = SCRUB_NO_KEY, key_path = nil, parent = nil)
      return SCRUB_ELIDED if (budget[0] -= 1).negative?

      if defined?(::ActionController::Parameters) && ::ActionController::Parameters === value
        value = value.instance_variable_get(:@parameters)
        return SCRUB_ELIDED unless value.is_a?(Hash)
      end
      return scrub_leaf(key, value, parent) unless value.is_a?(Hash) || value.is_a?(Array)
      return SCRUB_ELIDED if depth >= SCRUB_MAX_DEPTH || path.any? { |container| container.equal?(value) }

      path.push(value)
      begin
        if value.is_a?(Hash)
          holder = [ value ]
          value.first(SCRUB_MAX_ENTRIES).to_h do |name, item|
            name_path = key_path ? "#{key_path}.#{name}" : name.to_s
            [ name, scrub_key?(name, name_path) ? FILTERED : scrub_value(item, depth + 1, path, budget, name, name_path, holder) ]
          end
        else
          value.first(SCRUB_MAX_ENTRIES).map { |item| scrub_value(item, depth + 1, path, budget, key, key_path, parent) }
        end
      ensure
        path.pop
      end
    end

    def shaped_secrets(path, entries)
      secrets = nil
      entries.each do |pattern, names, children|
        match = pattern.match(path) or next
        captures = match.named_captures
        names.each do |name|
          value = captures[name]
          next if value.nil? || value.empty?

          value = CGI.unescapeURIComponent(value) if value.include?("%")
          (secrets ||= []) << value
        end
        if children
          rest = match.post_match
          found = shaped_secrets(rest.start_with?("/") ? rest : "/#{rest}", children)
          (secrets ||= []).concat(found) unless found.empty?
        end
      end
      secrets || NO_SECRETS
    end

    # segment itself when it does not hold secret, as the same object.
    def filter_segment(segment, secret)
      return segment if segment.empty?

      plain = unescape(segment)
      return FILTERED if plain == secret
      return "#{FILTERED}#{plain[secret.length..]}" if plain.start_with?(secret) && plain[secret.length] == "."

      segment
    end

    def unescape(segment)
      segment.include?("%") ? CGI.unescapeURIComponent(segment) : segment
    end

    # path with each run of whole segments that decodes to secret (a glob
    # value, "a/b") replaced by [FILTERED], whichever of its bytes, "/"
    # included, are percent-encoded. Compared byte by byte on the decoded
    # path; each decoded byte remembers where it started in path.
    def filter_glob(path, secret)
      raw = path.b
      target = secret.b
      decoded = +"".b
      origin = []
      i = 0
      while i < raw.bytesize
        origin << i
        hex = raw.getbyte(i) == 37 && raw.byteslice(i + 1, 2)
        if hex && hex.match?(/\A\h\h\z/)
          decoded << hex.to_i(16).chr
          i += 3
        else
          decoded << raw.byteslice(i)
          i += 1
        end
      end
      origin << raw.bytesize

      out = +"".b
      kept = 0
      from = 0
      while (at = decoded.index(target, from))
        finish = at + target.bytesize
        before = origin[at].zero? ? nil : raw.getbyte(origin[at] - 1)
        after = raw.getbyte(origin[finish])
        if before == 47 && (after.nil? || after == 47 || after == 46)
          out << raw.byteslice(kept...origin[at]) << FILTERED
          kept = origin[finish]
          from = finish
        else
          from = at + 1
        end
      end
      return path if kept.zero?

      (out << raw.byteslice(kept..)).force_encoding(path.encoding)
    end

    # Fails closed, like #params. A dotted filter ("billing.number") names
    # the whole path, so a nested key is also tried with its parents. Any
    # key is matched by its #to_s, as the parameter filter matches one
    # (`{ 42 => ... }` against /\A42\z/).
    def scrub_key?(key, key_path)
      name = key.to_s
      param_filter.filter_param(name, name) != name ||
        (key_path != name && param_filter.filter_param(key_path, key_path) != key_path)
    rescue StandardError
      true
    end

    # A value under a key no filter names, given to the app's Proc filters
    # as the value itself: one that masks by what the value holds (a
    # four-digit pin) cannot tell from the key's name alone. Called as the
    # parameter filter calls them, on copies, except that the third
    # argument (the original params, which #filter_param has no way to
    # pass) is the Hash the key is in, not the root of what is scrubbed: a
    # frozen copy of its first SCRUB_MAX_ENTRIES entries, made once per
    # Hash. Fails closed.
    def scrub_leaf(key, value, parent)
      return value if key.equal?(SCRUB_NO_KEY)

      procs = proc_filters
      return value if procs.empty?

      name = key.to_s
      value = value.dup if value.duplicable?
      procs.each do |filter|
        next filter.call(name.dup, value) if filter.arity == 2

        filter.call(name.dup, value, parent && (parent[1] ||= original_for(parent[0])))
      end
      value
    rescue StandardError
      FILTERED
    end

    def original_for(hash)
      copy = hash.size > SCRUB_MAX_ENTRIES ? hash.class[hash.first(SCRUB_MAX_ENTRIES)] : hash.dup
      copy.freeze
    end

    def sensitive_path_parameter?(name)
      SENSITIVE_PATH_PARAMETER.match?(name) || param_filter.filter_param(name, name) != name
    end

    # [pattern, sensitive segment names, entries of a mounted engine] for
    # each of the app's routes that has a credential-shaped dynamic segment,
    # or mounts an engine that does. Built once per route set; a route
    # reload (development) changes its size or last route and rebuilds it.
    def sensitive_routes
      return NO_SECRETS unless defined?(Rails) && Rails.application

      routes = Rails.application.routes.set.routes
      key = [ routes.length, routes.last.object_id ]
      return @sensitive_routes if @sensitive_routes_key == key

      @sensitive_routes = collect_sensitive_routes(Rails.application.routes)
      @sensitive_routes_key = key
      @sensitive_routes
    end

    def collect_sensitive_routes(route_set, depth = 0)
      route_set.set.routes.filter_map do |route|
        names = route.path.names.select { |name| !ROUTING_PATH_PARAMETERS.include?(name.to_sym) && sensitive_path_parameter?(name) }
        app = route.app
        children = if depth < 4 && !route.path.anchored && app.respond_to?(:engine?) && app.engine?
          found = collect_sensitive_routes(app.rack_app.routes, depth + 1)
          found unless found.empty?
        end
        [ route.path, names, children ] unless names.empty? && children.nil?
      end
    end

    def param_filter
      @param_filter ||= ActiveSupport::ParameterFilter.new(filters, mask: FILTERED)
    end

    def proc_filters
      @proc_filters ||= filters.grep(Proc)
    end

    def filters
      filters = @config.redact_params.dup
      filters.concat(Rails.application.config.filter_parameters) if defined?(Rails) && Rails.application
      filters.uniq
    end
  end
end
