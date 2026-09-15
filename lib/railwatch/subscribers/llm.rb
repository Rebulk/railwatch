# frozen_string_literal: true

module Railwatch
  module Subscribers
    # RubyLLM's own instrumentation. It emits an ActiveSupport::Notifications
    # event per model call -- chat, embedding, image, and the rest -- plus one
    # per tool invocation, so nothing here patches RubyLLM; we subscribe the
    # same way we subscribe to Rails.
    #
    # One `llm_call` record per event, with `operation` naming which kind it
    # was. Tool calls are the same record with operation "tool": they sit in
    # the same execution waterfall and carry no tokens or cost.
    #
    # Two RubyLLM generations are supported. 1.16 puts token counts on the
    # event as scalars and reports no cost at all; 2.0 sends Tokens and Cost
    # objects built from its usage ledger. Both normalise to the same wire
    # record, so a 1.16 app simply has no cost. Subscribing to an event
    # RubyLLM never emits costs nothing, so the operations 2.0 added are
    # subscribed unconditionally rather than behind a version check.
    module Llm
      extend Base

      module_function

      # Every usage-bearing operation in RubyLLM 2.0. The ones 1.16 knows
      # about (chat, embedding, image, transcription, moderation) emit the
      # same event names, so this list needs no version branch. `compaction`
      # is a chat call by another name -- same payload, same tokens, same
      # cost -- and is billed, so it belongs here rather than being invisible
      # spend.
      OPERATIONS = %w[chat compaction embedding image speech transcription
                      moderation rerank ocr].freeze

      # Costs are fractions of a cent: a cheap model's call is well under a
      # microdollar, and floats summed across a month of rollups do not add
      # up to an invoice. Nanodollars keep it exact in an integer column
      # ($1,000 is 1e12, comfortably inside i64).
      NANOS_PER_DOLLAR = 1_000_000_000

      # Matches capture_response_body_on_error's cap. Prompts and completions
      # are free text an app controls, so this is a size bound, not redaction.
      CONTENT_MAX = 4096

      def install!(_app)
        OPERATIONS.each do |operation|
          subscribe("#{operation}.ruby_llm") { |event| record_call(operation, event) }
        end
        subscribe("tool_call.ruby_llm") { |event| record_tool(event) }
      end

      def record_call(operation, event)
        exe = execution
        exe&.count(:llm_calls)
        return unless recording?

        p = event.payload
        provider = p[:provider].to_s
        model = p[:model].to_s
        Railwatch.record(:llm_call,
          group: Record.group_hash(provider, model, operation),
          timestamp: started_at(event),
          operation: operation,
          provider: provider,
          model: model,
          response_model: p[:response_model]&.to_s&.slice(0, 255),
          duration: micros(event),
          streaming: p[:streaming] == true,
          message_count: p[:message_count],
          tool_count: Array(p[:tools]).size,
          cost_nanos: cost_nanos(p),
          **tokens(p),
          **workflow(p),
          **outcome(p),
          prompt: content(prompt_text(p)),
          completion: content(message_text(p[:response])))
      end

      # RubyLLM's opt-in tool_concurrency (:threads or :fibers) runs each
      # tool in a fresh thread or fiber, and Current is backed by
      # IsolatedExecutionState, which a new thread does not inherit. So this
      # fires with no execution and the record is dropped.
      #
      # It cannot be fixed from here: by the time the event is delivered we
      # are already inside the worker, with no reference to the execution
      # that spawned it, and the thread is RubyLLM's to create
      # (chat/tool_concurrency.rb propagates its own workflow context across
      # that boundary, but knows nothing of ours). The same is true of every
      # subscriber in an app-spawned thread. Dropping beats guessing: a
      # process-wide fallback would file one request's tool call under
      # another's execution. Concurrency is off by default, and the model
      # calls are unaffected either way, so cost stays complete.
      def record_tool(event)
        exe = execution
        exe&.count(:llm_calls)
        return unless recording?

        p = event.payload
        tool_name = p[:tool_name].to_s
        Railwatch.record(:llm_call,
          group: Record.group_hash("tool", tool_name),
          timestamp: started_at(event),
          operation: "tool",
          provider: p[:provider].to_s,
          model: p[:model].to_s,
          tool_name: tool_name[0, 255],
          duration: micros(event),
          **workflow(p),
          **outcome(p),
          prompt: content(p[:tool_arguments]),
          completion: content(p[:result_content]))
      end

      # 2.0 sends a RubyLLM::Tokens; 1.16 sends bare counts on the event.
      def tokens(payload)
        counts = payload[:tokens]
        if counts.respond_to?(:input)
          { input_tokens: counts.input, output_tokens: counts.output,
            cache_read_tokens: counts.cache_read, cache_write_tokens: counts.cache_write,
            thinking_tokens: counts.thinking }
        else
          { input_tokens: payload[:input_tokens], output_tokens: payload[:output_tokens],
            cache_read_tokens: payload[:cached_tokens], cache_write_tokens: payload[:cache_creation_tokens],
            thinking_tokens: payload[:thinking_tokens] }
        end
      end

      # nil in three distinct cases that all mean "we do not know": RubyLLM
      # 1.16 (which reports no cost), a model the registry has no pricing
      # for, and an operation that used no tokens. Never zero -- an unpriced
      # call is not a free call, and the difference matters on a bill.
      def cost_nanos(payload)
        cost = payload[:cost]
        return nil unless cost.respond_to?(:total)

        total = cost.total
        total && (total * NANOS_PER_DOLLAR).round
      end

      # Present only on 2.0, and only inside RubyLLM.workflow. Stamped on
      # every event the block emits, which is what lets an agent run be
      # reassembled from its steps.
      def workflow(payload)
        return {} unless payload[:workflow_id]

        { workflow_id: payload[:workflow_id].to_s[0, 64],
          workflow_name: payload[:workflow_name].to_s[0, 255],
          workflow_step_id: payload[:workflow_step_id]&.to_s&.slice(0, 64),
          workflow_step_name: payload[:workflow_step_name]&.to_s&.slice(0, 255),
          workflow_step_parent_id: payload[:workflow_step_parent_id]&.to_s&.slice(0, 64) }
      end

      # Rails adds :exception to the payload when the instrumented block
      # raised; RubyLLM leaves the rest of the event untouched in that case.
      def outcome(payload)
        error = payload[:exception]
        return { status: "ok" } unless error

        { status: "failed", error: "#{Array(error).first}: #{Array(error).last}"[0, 255] }
      end

      # The last thing the app asked, which is the half of a conversation
      # worth seeing next to a cost. Earlier turns are the app's own records.
      def prompt_text(payload)
        messages = payload[:input_messages]
        return payload[:input] || payload[:prompt] || payload[:query] unless messages.respond_to?(:reverse_each)

        last = messages.reverse_each.find { |m| m.respond_to?(:role) && m.role.to_s == "user" }
        message_text(last)
      end

      def message_text(message)
        return nil if message.nil?

        message.respond_to?(:content) ? message.content : message
      end

      def content(value)
        return nil unless Railwatch.config.capture_llm_content
        return nil if value.nil?

        text = value.to_s
        return nil if text.empty?
        # byteslice, not [0, n]: the cap bounds what is buffered and shipped,
        # and 4096 characters of CJK is three times that in bytes. scrub
        # repairs the multibyte character the slice may have cut in half.
        text.bytesize > CONTENT_MAX ? text.byteslice(0, CONTENT_MAX).scrub("") : text
      end
    end
  end
end
