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
          tools: tool_names(p),
          cost_nanos: cost_nanos(p),
          cost_reported: cost_reported(p),
          finish_reason: finish_reason(p),
          provider_request_id: provider_request_id(p),
          params: params(operation, p),
          **attachments(p),
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
          tool_call_id: p[:tool_call_id]&.to_s&.slice(0, 128),
          params: ({ result_class: p[:result_class].to_s[0, 128] } if p[:result_class]),
          duration: micros(event),
          **workflow(p),
          **outcome(p),
          prompt: content(p[:tool_arguments]),
          completion: content(p[:result_content]))
      end

      # Why the model stopped. :max_tokens means the answer was cut off --
      # a truncated extraction reads exactly like a complete one without
      # this, which is the failure most worth being able to see.
      def finish_reason(payload)
        response = payload[:response]
        return nil unless response.respond_to?(:finish_reason)

        response.finish_reason&.to_s&.slice(0, 32)
      end

      # Message#raw is the Faraday response (protocol.rb hands it in), so the
      # provider's own request id is in its headers. It is what a provider
      # support ticket asks for, and the only key that joins our record to
      # theirs.
      REQUEST_ID_HEADERS = %w[request-id x-request-id x-amzn-requestid].freeze

      def provider_request_id(payload)
        raw = payload[:response]
        raw = raw.raw if raw.respond_to?(:raw)
        headers = raw.respond_to?(:headers) ? raw.headers : nil
        return nil unless headers.respond_to?(:[])

        REQUEST_ID_HEADERS.each do |name|
          value = headers[name]
          return value.to_s[0, 128] if value.present?
        end
        nil
      end

      # Which tools the model could reach on this call. tool_count alone says
      # how many; retracing needs which.
      def tool_names(payload)
        names = Array(payload[:tools]).map(&:to_s)
        names.empty? ? nil : names.first(50).join(",")[0, 1024]
      end

      # Whether the provider priced the call itself, or we estimated it from
      # the registry. The difference matters when a total is queried against
      # an invoice.
      def cost_reported(payload)
        tokens = payload[:tokens]
        return nil unless tokens.respond_to?(:reported_cost)
        # No cost means no provenance to report. false would claim the
        # registry priced it, which is the same false certainty cost_nanos
        # avoids by being nil rather than zero.
        return nil if cost_nanos(payload).nil?

        !tokens.reported_cost.nil?
      end

      # What the call carried besides text. Images and PDFs are most of the
      # input tokens on a document-reading call, and without this an
      # expensive scan is indistinguishable from an expensive prompt.
      # Only the last user turn is measured: earlier turns were counted by
      # the calls that sent them, and walking the whole history would both
      # double-count and cost O(messages) on every call.
      def attachments(payload)
        message = last_user_message(payload)
        list = message.respond_to?(:attachments) ? Array(message.attachments) : []
        return {} if list.empty?

        types = list.filter_map { |a| a.type.to_s if a.respond_to?(:type) }.tally
          .sort_by { |_, n| -n }.map { |type, n| n > 1 ? "#{type}x#{n}" : type }.join(",")
        { attachments: list.size, attachment_types: types[0, 128],
          attachment_names: content(list.filter_map { |a| a.filename if a.respond_to?(:filename) }.join(", ")) }
      end

      # The knobs that change what a call costs and what it returns, so a
      # surprising result can be reproduced with the settings that produced
      # it. Provider options go through the app's own parameter filter: they
      # are request configuration, but an app can put anything in them.
      COMMON_PARAMS = %i[temperature max_output_tokens tool_choice tool_call_limit
                         thinking caching citations dimensions task_type size count
                         voice format language pages document_count top_n].freeze

      def params(operation, payload)
        out = {}
        COMMON_PARAMS.each do |key|
          value = payload[key]
          next if value.nil?
          # false is kept, not dropped: `caching` defaults to nil, so
          # caching: false is a deliberate choice, and reproducing a call
          # needs the settings it ran with. RubyLLM does not distinguish a
          # boolean that was set from one that defaulted, so record both
          # rather than guess which mattered.
          out[key] = value.is_a?(Numeric) || [ true, false ].include?(value) ? value : value.to_s[0, 128]
        end
        out[:schema] = true if payload[:schema]
        out[:server_tools] = Array(payload[:server_tools]).map(&:to_s).first(20) if payload[:server_tools].present?
        if (usage = payload[:tokens]).respond_to?(:server_tool_use) && usage.server_tool_use.present?
          out[:server_tool_use] = usage.server_tool_use
        end
        if (options = payload[:provider_options]).is_a?(Hash) && !options.empty?
          out[:provider_options] = provider_options(options)
        end
        out[:operation] = operation unless out.empty?
        out.empty? ? nil : out
      end

      # Two filters, because one is not enough here. The app's parameter
      # filter defaults to password-shaped names only, and provider_options
      # is the one place in this payload where a per-request credential
      # plausibly lives -- an api_key passed per call sails straight through
      # a password filter. The redactor's credential-name matcher (the same
      # one that catches X-Api-Key on a header) closes that.
      def provider_options(options)
        redact_credentials(Railwatch.redactor.params(options.transform_keys(&:to_s)))
      end

      # Recursive, because provider options nest: extra_headers carrying an
      # authorization value is a hash inside the hash, and a top-level scan
      # walks straight past it.
      def redact_credentials(value, depth = 0)
        return value if depth > 4

        case value
        when Hash
          value.each_with_object({}) do |(key, item), out|
            # The matcher is written for header names, which are hyphenated;
            # provider options are Ruby-ish and use underscores, so api_key
            # would sail past a pattern expecting api-key.
            out[key] = if Railwatch.redactor.redact_header?(key.to_s.tr("_", "-"))
              Redactor::FILTERED
            else
              redact_credentials(item, depth + 1)
            end
          end
        when Array then value.map { |item| redact_credentials(item, depth + 1) }
        else value
        end
      end

      def last_user_message(payload)
        messages = payload[:input_messages]
        return nil unless messages.respond_to?(:reverse_each)

        messages.reverse_each.find { |m| m.respond_to?(:role) && m.role.to_s == "user" }
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
        return payload[:input] || payload[:prompt] || payload[:query] unless payload[:input_messages].respond_to?(:reverse_each)

        message_text(last_user_message(payload))
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
