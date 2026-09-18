# frozen_string_literal: true

module Railwatch
    class LlmCallsController < DashboardController
    NANOS_PER_DOLLAR = 1_000_000_000.0

    def index
      from, to = window_range
      fields = FilterQuery.parse(params[:q]).fetch(:fields)
      models = telemetry { model_rows(from, to) }
      tools = telemetry { tool_rows(from, to) }
      rows = telemetry { recent_rows(fields) }
      render inertia: { models: models, tools: tools, recent: rows,
                       totals: totals(models, tools),
                       # Two record types over one table, the way Execution
                       # feeds request/job_attempt/... Waiting on a model is
                       # seconds of somebody else's compute; a tool call is
                       # your own code in milliseconds. One p95 over both
                       # describes neither.
                       series: series("llm_call"), tool_series: series("llm_tool"),
                       q: params[:q].to_s }
    end

    private

    # One row per provider/model/operation group, from rollups: tokens and
    # spend come out of Rollup#extra, which sums them on merge, so a 30-day
    # window costs the same few rows as an hour.
    def model_rows(from, to)
      Telemetry::Rollup.for_type("llm_call").between(from, to).to_a
        .group_by(&:group_hash).map { |group_hash, group_rows| model_row(group_hash, group_rows, from, to) }
        .sort_by { |r| [ -(r[:cost] || 0), -r[:count] ] }.first(200)
    end

    # Tools have no tokens and no price, so they rank by how much time they
    # actually cost the request: slowest first.
    def tool_rows(from, to)
      Telemetry::Rollup.for_type("llm_tool").between(from, to).to_a
        .group_by(&:group_hash).map do |group_hash, group_rows|
          summary = Telemetry::Rollup.summarize(group_rows)
          { group_hash: group_hash, name: group_rows.max_by(&:bucket).name,
           count: group_rows.sum(&:count), errors: group_rows.sum(&:error_count),
           avg: (summary[:avg] / 1000.0).round(2), p95: (summary[:p95] / 1000.0).round(2),
           max: (summary[:max] / 1000.0).round(2),
           sparkline: Telemetry::Aggregations.sparkline(group_rows, from, to) }
        end.sort_by { |r| -r[:p95] }.first(200)
    end

    def model_row(group_hash, group_rows, from, to)
      count = group_rows.sum(&:count)
      summary = Telemetry::Rollup.summarize(group_rows)
      nanos = sum_extra(group_rows, "cost_nanos")
      priced = sum_extra(group_rows, "priced")
      unpriced = sum_extra(group_rows, "unpriced")
      {
        group_hash: group_hash, name: group_rows.max_by(&:bucket).name, count: count,
        errors: group_rows.sum(&:error_count),
        input_tokens: sum_extra(group_rows, "input_tokens"), output_tokens: sum_extra(group_rows, "output_tokens"),
        cache_read_tokens: sum_extra(group_rows, "cache_read_tokens"),
        cache_write_tokens: sum_extra(group_rows, "cache_write_tokens"),
        # nil, not 0, when nothing in the group was priced: a table that shows
        # $0.00 for an unpriced model is lying about the bill. `unpriced`
        # carries how many calls the figure leaves out when it is partial.
        cost: priced.zero? ? nil : nanos / NANOS_PER_DOLLAR, unpriced: unpriced,
        # Neither of these is an error, so neither shows in the error rate.
        truncated: sum_extra(group_rows, "truncated"),
        with_attachments: sum_extra(group_rows, "with_attachments"),
        avg: (summary[:avg] / 1000.0).round(2), p95: (summary[:p95] / 1000.0).round(2),
        sparkline: Telemetry::Aggregations.sparkline(group_rows, from, to)
      }
    end

    def sum_extra(rows, key)
      rows.sum { |r| r.extra[key].to_i }
    end

    # `count` is model calls only. Tool calls are counted separately rather
    # than folded in: they cost no tokens and no money, so adding them to the
    # headline number inflates it with work that never reached a provider.
    def totals(models, tools)
      priced = models.reject { |m| m[:cost].nil? }
      {
        count: models.sum { |m| m[:count] }, errors: models.sum { |m| m[:errors] },
        tool_count: tools.sum { |t| t[:count] }, tool_errors: tools.sum { |t| t[:errors] },
        input_tokens: models.sum { |m| m[:input_tokens] }, output_tokens: models.sum { |m| m[:output_tokens] },
        cost: priced.empty? ? nil : priced.sum { |m| m[:cost] }, unpriced: models.sum { |m| m[:unpriced] }
      }
    end

    def recent_rows(fields)
      scope = Telemetry::LlmCall.between(*window_range)
      scope = scope.where("model LIKE ?", "%#{Telemetry::LlmCall.sanitize_sql_like(fields['model'])}%") if fields["model"].present?
      scope = scope.where(provider: fields["provider"]) if fields["provider"].present?
      scope = scope.where(operation: fields["operation"]) if fields["operation"].present?
      scope = scope.where(workflow_id: fields["workflow"]) if fields["workflow"].present?
      scope = scope.where(finish_reason: fields["finish"]) if fields["finish"].present?
      # "attachments:image" is the question a document-heavy app actually asks.
      if fields["attachments"].present?
        scope = if fields["attachments"] == "any"
          scope.where.not(attachments: nil)
        else
          scope.where("attachment_types LIKE ?", "%#{Telemetry::LlmCall.sanitize_sql_like(fields['attachments'])}%")
        end
      end
      scope.recent.limit(200).map { |r| row_props(r) }
    end

    def row_props(call)
      { id: call.id, operation: call.operation, provider: call.provider, model: call.model,
       response_model: call.response_model, tool_name: call.tool_name, duration: call.duration_ms.round(1),
       status: call.status, error: call.error, streaming: call.streaming, message_count: call.message_count,
       tool_count: call.tool_count, input_tokens: call.input_tokens, output_tokens: call.output_tokens,
       cache_read_tokens: call.cache_read_tokens, cache_write_tokens: call.cache_write_tokens,
       thinking_tokens: call.thinking_tokens, cost: call.cost, cost_reported: call.cost_reported,
       workflow_id: call.workflow_id, workflow_name: call.workflow_name,
       workflow_step_name: call.workflow_step_name,
       finish_reason: call.finish_reason, provider_request_id: call.provider_request_id,
       tools: call.tools, attachments: call.attachments, attachment_types: call.attachment_types,
       attachment_names: call.attachment_names, tool_call_id: call.tool_call_id, params: call.params,
       prompt: call.prompt, completion: call.completion, occurred_at: call.occurred_at,
       execution_id: call.execution_id, execution_preview: call.execution_preview }
    end
    end
end
