# frozen_string_literal: true

module Lantern
  # Builds the flat hash that goes over the wire. Every record carries the same
  # envelope keys as Nightwatch (v, t, timestamp, deploy, server, _group,
  # trace_id, execution_*, user) plus tenant.
  module Record
    VERSIONS = {
      request: 1, job_attempt: 1, scheduled_task: 1, command: 1,
      query: 1, n_plus_one: 1, transaction: 1, exception: 1, cache_event: 1, mail: 1,
      broadcast: 1, notification: 1, outgoing_request: 1, storage_op: 1, view_render: 1,
      log: 1, enqueued_job: 1, user: 1, deprecation: 1, visit: 1, process: 1, span: 1, health: 1
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
      config = Lantern.config
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

    # 128-bit grouping hash. MD5 is the fastest 128-bit digest in stdlib and
    # is only used for bucketing, never for security.
    def group_hash(*parts)
      Digest::MD5.hexdigest(parts.join(","))
    end
  end
end
