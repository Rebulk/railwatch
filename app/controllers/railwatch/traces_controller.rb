# frozen_string_literal: true

# One distributed trace: every execution that shares a trace_id, nested by
# the parent_id the gem propagates (the enqueuing execution's id for jobs,
# the W3C traceparent parent-id for HTTP hops).
module Railwatch
    class TracesController < DashboardController
    LIMIT = 200

    def show
      trace_id = params[:trace_id]
      executions, outgoing = telemetry do
        rows = Telemetry::Execution.where(trace_id: trace_id).order(:occurred_at).limit(LIMIT).to_a
        [ rows, Telemetry::OutgoingRequest.where(execution_id: rows.map(&:execution_id)).order(:occurred_at).group_by(&:execution_id) ]
      end
      raise ActiveRecord::RecordNotFound if executions.empty?

      @start = executions.first.occurred_at
      @outgoing = outgoing
      render inertia: { trace_id: trace_id, roots: tree(executions),
                        span_count: executions.size + outgoing.values.sum(&:size),
                        services: executions.filter_map(&:server).uniq, duration: total_duration(executions) }
    end

    private

    # An execution's parent is the one whose execution_id matches its
    # parent_id outright (a job enqueued by that execution) or whose id
    # matches once dashes are dropped and it is cut to the 16 hex chars a
    # W3C traceparent carries (an incoming HTTP hop). Anything whose parent
    # is missing -- the trace's entry point, or a hop whose caller was not
    # reported -- is a root.
    def tree(executions)
      by_id = executions.index_by(&:execution_id)
      by_short_id = executions.index_by { |e| e.execution_id.to_s.delete("-").first(16) }
      children = Hash.new { |hash, key| hash[key] = [] }
      roots = []
      executions.each do |exe|
        parent = exe.parent_id.presence && (by_id[exe.parent_id] || by_short_id[exe.parent_id])
        parent = nil if parent && parent.execution_id == exe.execution_id
        parent ? children[parent.execution_id] << exe : roots << exe
      end
      roots.map { |exe| node(exe, children) }
    end

    def node(exe, children)
      { execution: execution_row(exe), children: children[exe.execution_id].map { |child| node(child, children) } }
    end

    def execution_row(exe)
      { execution_id: exe.execution_id, kind: exe.kind, name: exe.name, status: exe.status, outcome: exe.outcome,
        parent_id: exe.parent_id, server: exe.server, occurred_at: exe.occurred_at,
        duration: exe.duration_ms.round(2), offset: offset(exe.occurred_at),
        outgoing: @outgoing.fetch(exe.execution_id, []).map { |o| outgoing_row(o) } }
    end

    def outgoing_row(o)
      { id: o.id, method: o.method, url: o.url.to_s.first(200), status_code: o.status_code,
        duration: o.duration_ms&.round(2), offset: offset(o.occurred_at) }
    end

    def offset(time)
      ((time - @start) * 1000.0).round(2)
    end

    # Wall-clock span of the whole trace: the last thing to finish, minus the
    # first thing to start.
    def total_duration(executions)
      executions.map { |e| offset(e.occurred_at) + e.duration_ms }.max.round(2)
    end
    end
end
