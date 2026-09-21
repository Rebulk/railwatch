# frozen_string_literal: true

module Railwatch
  # Everything the execution detail page needs: the parent, its waterfall
  # timeline of children, exceptions with frames, logs, and links to the
  # enqueuing request or the jobs it enqueued.
  class ExecutionPresenter
    # The profile page renders up to 2 MiB of collapsed stacks; the execution
    # page only carries an inline preview flamegraph alongside everything else
    # it already ships, so it takes a smaller slice and links out when cut.
    INLINE_COLLAPSED_BYTES = 512.kilobytes

    # Everything an attachment row needs except `data`, which is the whole
    # gzipped file and never belongs in a page prop.
    ATTACHMENT_COLUMNS = %i[id name content_type bytes truncated occurred_at execution_stage].freeze

    def initialize(execution, environment)
      @exe = execution
      @environment = environment
    end

    def props
      @environment.with_telemetry do
        {
          execution: base,
          timeline: timeline,
          exceptions: @exe.exceptions.map { |e| exception_row(e) },
          logs: @exe.logs.order(:occurred_at).limit(500).map { |l| { id: l.id, level: l.level, message: l.message, tags: l.tags, occurred_at: l.occurred_at, stage: l.execution_stage } },
          queries: @exe.queries.order(:occurred_at).limit(500).with_sql.map { |q| { id: q.id, sql: q.sql, duration: q.duration_ms.round(3), source: q.source, group_hash: q.group_hash, row_count: q.row_count, stage: q.execution_stage, offset: offset(q) } },
          spans: spans,
          profile: profile_card,
          attachments: attachment_rows.map { |a| attachment_row(a) },
          enqueued_jobs: enqueued_jobs,
          parent: parent,
          trace: trace,
          trace_url: trace_url,
          issues: issues,
          person: person
        }
      end
    end

    # Public so the issue page can build breadcrumbs from an occurrence's
    # execution without re-implementing the per-type mapping.
    def timeline_entries
      timeline
    end

    private

    def base
      {
        execution_id: @exe.execution_id, kind: @exe.kind, name: @exe.name, duration: @exe.duration_ms.round(3), status: @exe.status,
        outcome: @exe.outcome, method: @exe.method, route: @exe.route, controller: @exe.controller, action: @exe.action,
        queue: @exe.queue, attempt: @exe.attempt, queue_latency: @exe.queue_latency && (@exe.queue_latency / 1000.0).round(1),
        queue_time: @exe.queue_time && (@exe.queue_time / 1000.0).round(1),
        job_id: @exe.job_id, task_key: @exe.task_key, inertia_component: @exe.inertia_component,
        occurred_at: @exe.occurred_at, deploy: @exe.deploy, server: @exe.server, user_ref: @exe.user_ref, tenant: @exe.app_tenant,
        trace_id: @exe.trace_id, allocations: @exe.allocations, peak_memory: @exe.peak_memory, exception_preview: @exe.exception_preview,
        profiled: profile.present?,
        stages: @exe.stages.transform_values { |v| (v / 1000.0).round(3) }, counters: @exe.counters, detail: @exe.detail
      }
    end

    def offset(row)
      ((row.occurred_at - @exe.occurred_at) * 1000.0).round(3)
    end

    # Rich waterfall entries for the Timeline component: unlike the model's
    # generic `timeline_label`, this keeps type-specific fields (sql, status,
    # subject, level...) so the frontend can render a real hover/detail panel
    # instead of a truncated string.
    def timeline
      entries = []
      @exe.queries.with_sql.each { |q| entries << { type: "query", id: q.id, offset: offset(q), duration: q.duration_ms, stage: q.execution_stage,
        label: q.sql.to_s.first(120), sql: q.sql, source: q.source, detail: { "rows" => q.row_count, "connection" => q.connection } } }
      @exe.cache_events.each { |c| entries << { type: "cache_event", id: c.id, offset: offset(c), duration: c.duration_ms, stage: c.execution_stage,
        label: "#{c.type} #{c.key}".first(120), source: nil, detail: { "key" => c.key, "op" => c.type, "store" => c.store, "hits" => c.hits, "ttl" => c.ttl } } }
      @exe.outgoing_requests.each { |o| entries << { type: "outgoing_request", id: o.id, offset: offset(o), duration: o.duration_ms, stage: o.execution_stage,
        label: o.url.to_s.first(120), source: o.source, detail: { "method" => o.method, "url" => o.url, "status" => o.status_code, "host" => o.host, "error" => o.error, "body" => o.response_body } } }
      @exe.mails.each { |m| entries << { type: "mail", id: m.id, offset: offset(m), duration: m.duration_ms, stage: m.execution_stage,
        label: m.mailer.to_s.first(120), source: nil, detail: { "subject" => m.subject, "mailer" => m.mailer, "to" => m.to } } }
      @exe.logs.each { |l| entries << { type: "log", id: l.id, offset: offset(l), duration: l.duration_ms, stage: l.execution_stage,
        label: l.message.to_s.first(120), source: l.source, detail: { "level" => l.level, "message" => l.message.to_s.first(500) } } }
      @exe.exceptions.each { |e| entries << { type: "exception", id: e.id, offset: offset(e), duration: e.duration_ms, stage: e.execution_stage,
        label: "#{e.class_name}: #{e.message.to_s.first(100)}", source: (e.file ? "#{e.file}:#{e.line}" : nil), detail: { "class" => e.class_name, "message" => e.message.to_s.first(300), "handled" => e.handled } } }
      @exe.broadcasts.each { |b| entries << { type: "broadcast", id: b.id, offset: offset(b), duration: b.duration_ms, stage: b.execution_stage,
        label: b.channel.to_s.first(120), source: nil, detail: { "channel" => b.channel, "action" => b.action, "stream" => b.stream } } }
      @exe.storage_ops.each { |s| entries << { type: "storage_op", id: s.id, offset: offset(s), duration: s.duration_ms, stage: s.execution_stage,
        label: "#{s.op} #{s.key}".first(120), source: nil, detail: { "op" => s.op, "key" => s.key, "service" => s.service } } }
      @exe.view_renders.each { |v| entries << { type: "view_render", id: v.id, offset: offset(v), duration: v.duration_ms, stage: v.execution_stage,
        label: v.identifier.to_s.first(120), source: nil, detail: { "count" => v.count, "cache_hits" => v.cache_hits } } }
      @exe.enqueued_jobs.each { |j| entries << { type: "enqueued_job", id: j.id, offset: offset(j), duration: j.duration_ms, stage: j.execution_stage,
        label: j.name.to_s.first(120), source: nil, detail: { "queue" => j.queue, "job_id" => j.job_id } } }
      @exe.spans.each { |s| entries << { type: "span", id: s.id, offset: offset(s), duration: s.duration_ms, stage: s.execution_stage,
        label: s.name.to_s.first(120), source: nil, detail: { "status" => s.status }.merge(s.payload) } }
      @exe.transactions.each { |t| entries << { type: "transaction", id: t.id, offset: offset(t), duration: t.duration_ms, stage: t.execution_stage,
        label: t.outcome.to_s.first(120), source: nil, detail: { "outcome" => t.outcome, "connection" => t.connection } } }
      @exe.llm_calls.each { |c| entries << { type: "llm_call", id: c.id, offset: offset(c), duration: c.duration_ms, stage: c.execution_stage,
        label: c.timeline_label.first(120), source: nil, detail: { "operation" => c.operation, "provider" => c.provider, "model" => c.model,
          "tool" => c.tool_name, "input_tokens" => c.input_tokens, "output_tokens" => c.output_tokens, "cost" => c.cost,
          "status" => c.status, "error" => c.error, "workflow" => c.workflow_name, "step" => c.workflow_step_name } } }
      attachment_rows.each { |a| entries << { type: "attachment", id: a.id, offset: offset(a), duration: nil, stage: a.execution_stage,
        label: a.name.to_s.first(120), source: nil, detail: { "name" => a.name, "content_type" => a.content_type, "bytes" => a.bytes, "truncated" => a.truncated } } }
      entries.each { |e| e[:duration] = e[:duration]&.round(3) }
      entries.sort_by { |e| e[:offset] }
    end

    def exception_row(e)
      { id: e.id, class_name: e.class_name, message: e.message, handled: e.handled, severity: e.severity, source: e.source,
        file: e.file, line: e.line, frames: e.frames, cause: e.cause, locals: e.locals, context: e.context, occurred_at: e.occurred_at, group_hash: e.group_hash }
    end

    def spans
      @exe.spans.order(:occurred_at).limit(200).map do |s|
        { id: s.id, name: s.name, duration: s.duration_ms&.round(3), status: s.status, attributes: s.payload,
          offset: offset(s), stage: s.execution_stage, occurred_at: s.occurred_at }
      end
    end

    # The execution's profile, if one was shipped. Looked up by execution_id
    # rather than through the denormalised executions.profile_id so a profile
    # that arrived in a later batch than its execution still shows up.
    def profile
      return @profile if defined?(@profile)
      @profile = @exe.profiles.recent.first
    end

    def profile_card
      row = profile or return nil
      collapsed, truncated = row.collapsed_capped(INLINE_COLLAPSED_BYTES)
      { id: row.id, profiler: row.profiler, mode: row.mode, interval: row.interval, duration: row.duration_ms.round(2),
        samples: row.samples, stacks_bytes: row.stacks_bytes, collapsed: collapsed, truncated: truncated }
    rescue Telemetry::BoundedGzip::Error
      nil
    end

    def attachment_rows
      @attachment_rows ||= @exe.attachments.order(:occurred_at).limit(50).select(*ATTACHMENT_COLUMNS).to_a
    end

    def attachment_row(a)
      { id: a.id, name: a.name, content_type: a.content_type, bytes: a.bytes, truncated: a.truncated,
        viewable: a.viewable?, occurred_at: a.occurred_at }
    end

    def enqueued_jobs
      @exe.enqueued_jobs.map do |j|
        attempt = Telemetry::Execution.jobs.find_by(job_id: j.job_id)
        { id: j.id, name: j.name, queue: j.queue, job_id: j.job_id, scheduled_at: j.scheduled_at, offset: offset(j),
          attempt_execution_id: attempt&.execution_id, attempt_outcome: attempt&.outcome }
      end
    end

    def parent
      return nil unless @exe.kind == "job_attempt" && @exe.trace_id
      p = Telemetry::Execution.where(trace_id: @exe.trace_id).where.not(execution_id: @exe.execution_id).order(:occurred_at).first
      p && { execution_id: p.execution_id, kind: p.kind, name: p.name }
    end

    def trace
      @trace ||= Telemetry::Execution.where(trace_id: @exe.trace_id).order(:occurred_at).limit(50)
        .map { |e| { execution_id: e.execution_id, kind: e.kind, name: e.name, duration: e.duration_ms.round(1), status: e.status, outcome: e.outcome,
          occurred_at: e.occurred_at, parent_id: e.parent_id, server: e.server, current: e.execution_id == @exe.execution_id } }
    end

    # Only worth linking out to the distributed trace page when this execution
    # is not the whole trace.
    def trace_url
      return nil unless @exe.trace_id && trace.size > 1
      Railwatch.url_helpers.application_environment_trace_path(@environment.application, @environment, @exe.trace_id)
    end

    def issues
      groups = @exe.exceptions.map(&:group_hash).uniq
      @environment.issues.where(group_hash: groups).map { |i| { id: i.id, key: i.key, title: i.title, status: i.status, group_hash: i.group_hash } }
    end

    def person
      return nil unless @exe.user_ref
      p = Telemetry::Person.find_by(ref: @exe.user_ref) or return nil
      { ref: p.ref, name: p.display_name, email: p.email }
    end
  end
end
