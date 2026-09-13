# frozen_string_literal: true

module Railwatch
  # Builds the flat hash that goes over the wire. Every record carries the same
  # envelope keys as Nightwatch (v, t, timestamp, deploy, server, _group,
  # trace_id, execution_*, user) plus tenant.
  module Record
    VERSIONS = {
      request: 1, job_attempt: 1, scheduled_task: 1, command: 1, channel_action: 1,
      query: 1, n_plus_one: 1, transaction: 1, exception: 1, cache_event: 1, mail: 1,
      broadcast: 1, notification: 1, outgoing_request: 1, storage_op: 1, view_render: 1,
      log: 1, enqueued_job: 1, user: 1, deprecation: 1, visit: 1, process: 1, span: 1, health: 1,
      profile: 1, attachment: 1, session: 1
    }.freeze

    # Used in place of an execution's envelope when there is no execution, so
    # build can splat unconditionally instead of allocating then merge!-ing.
    EMPTY_ENVELOPE = {}.freeze

    module_function

    # One hash literal: base keys, then the execution's (memoised) envelope,
    # then the caller's fields, each splat overriding the previous on
    # conflict -- same precedence as the old merge!/merge! chain, but built
    # in a single allocation instead of three.
    def build(type, execution, group: nil, timestamp: nil, **fields)
      config = Railwatch.config
      {
        v: VERSIONS.fetch(type),
        t: type.to_s,
        timestamp: timestamp || Clock.now,
        deploy: config.deploy,
        server: config.server,
        _group: group,
        **(execution ? execution.envelope : EMPTY_ENVELOPE),
        **fields
      }
    end

    # Bounds the walk below. A record is a flat-ish tree (headers, files, a
    # filtered payload); nothing legitimate is deeper, and the bound is also
    # what makes a self-referential structure terminate.
    MAX_SIZING_DEPTH = 8

    # How much resident memory a record costs, for the in-memory byte budgets
    # (Execution#buffer and Buffer#push). Deliberately an estimate built from
    # O(1) String#bytesize rather than a JSON encode: this runs on the request
    # thread for every record, and the exact NDJSON size is measured once,
    # later, on the reporter thread, while the batch is being written. The
    # constants are CRuby object overhead -- a String header, a Hash entry, an
    # Array slot -- so the estimate errs high, which is the safe direction for
    # a memory ceiling.
    #
    # Counting stops as soon as `limit` is exceeded: past that the only fact
    # the caller uses is "too big", so there is no reason to keep walking.
    def buffered_bytes(value, limit:, depth: 0)
      return limit + 1 if depth > MAX_SIZING_DEPTH

      bytes = case value
      when String then 40 + value.bytesize
      when Hash then hash_bytes(value, limit, depth)
      when Array then array_bytes(value, limit, depth)
      when Symbol then 16
      else 16
      end
      bytes > limit ? limit + 1 : bytes
    end

    def hash_bytes(hash, limit, depth)
      bytes = 80 + (hash.size * 40)
      hash.each do |key, value|
        bytes += buffered_bytes(key, limit: limit, depth: depth + 1)
        bytes += buffered_bytes(value, limit: limit, depth: depth + 1)
        break if bytes > limit
      end
      bytes
    end

    def array_bytes(array, limit, depth)
      bytes = 40 + (array.size * 8)
      array.each do |value|
        bytes += buffered_bytes(value, limit: limit, depth: depth + 1)
        break if bytes > limit
      end
      bytes
    end

    # 128-bit grouping hash. MD5 is the fastest 128-bit digest in stdlib and
    # is only used for bucketing, never for security.
    def group_hash(*parts)
      Digest::MD5.hexdigest(parts.join(","))
    end

    # URLs are metadata, not request payloads. Keep the useful origin/path
    # while dropping authority credentials, every query value, and fragments
    # without relying on strict parsing of application-provided redirects.
    def url_without_sensitive_components(value, limit:)
      url = value.to_s
      query = url.index("?")
      fragment = url.index("#")
      cutoff = query && fragment ? [ query, fragment ].min : query || fragment
      url = url[0, cutoff] if cutoff

      scheme_end = url.index("://")
      authority_start = if url.start_with?("//")
        2
      elsif scheme_end && /\A[A-Za-z][A-Za-z0-9+.-]*\z/.match?(url[0, scheme_end])
        scheme_end + 3
      end
      if authority_start
        authority_end = url.index("/", authority_start) || url.length
        userinfo_end = url.rindex("@", authority_end - 1)
        url = url[0, authority_start] + url[(userinfo_end + 1)..] if userinfo_end && userinfo_end >= authority_start
      end

      url[0, limit]
    end
  end
end
