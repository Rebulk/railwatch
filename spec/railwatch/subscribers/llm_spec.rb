# frozen_string_literal: true

require "spec_helper"

# RubyLLM is not a dependency of this gem: it publishes plain
# ActiveSupport::Notifications events, so the contract under test is the
# payload shape, not the library. These emit the payloads RubyLLM 1.16 and
# 2.0 emit, verbatim from their instrument call sites, which also means the
# specs keep working when an app has no LLM gem installed at all.
RSpec.describe Railwatch::Subscribers::Llm do
  # 2.0 sends objects built from its usage ledger.
  Tokens = Struct.new(:input, :output, :cache_read, :cache_write, :thinking, keyword_init: true)
  Cost = Struct.new(:total, keyword_init: true)
  Message = Struct.new(:role, :content, keyword_init: true)

  def in_execution
    Railwatch.config.sample[:commands] = 1.0
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    yield
  ensure
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                                         command: "rake demo", exit_code: 0)
  end

  def emit(name, payload)
    ActiveSupport::Notifications.instrument(name, payload) { nil }
  end

  def v2_chat_payload(**overrides)
    { chat: nil, provider: "anthropic", model: "claude-opus-5",
      input_messages: [ Message.new(role: :user, content: "How many tons?") ],
      message_count: 3, tools: [ :lookup, :convert ], streaming: false,
      tokens: Tokens.new(input: 1200, output: 340, cache_read: 900, cache_write: 0, thinking: 64),
      cost: Cost.new(total: 0.004275), response_model: "claude-opus-5" }.merge(overrides)
  end

  def v116_chat_payload(**overrides)
    # 1.16: token counts are scalars on the event and there is no cost key.
    { chat: nil, provider: "openai", model: "gpt-5.6",
      input_messages: [ Message.new(role: :user, content: "How many tons?") ],
      message_count: 3, tools: [], streaming: true,
      input_tokens: 800, output_tokens: 120, cached_tokens: 0,
      cache_creation_tokens: nil, thinking_tokens: nil, response_model: "gpt-5.6" }.merge(overrides)
  end

  describe "RubyLLM 2.0 payloads" do
    it "records one llm_call with the model, tokens, and cost in nanodollars" do
      in_execution { emit("chat.ruby_llm", v2_chat_payload) }

      call = railwatch_records(:llm_call).sole
      expect(call).to include(
        operation: "chat", provider: "anthropic", model: "claude-opus-5",
        response_model: "claude-opus-5", status: "ok", streaming: false,
        message_count: 3, tool_count: 2,
        input_tokens: 1200, output_tokens: 340, cache_read_tokens: 900,
        cache_write_tokens: 0, thinking_tokens: 64,
        cost_nanos: 4_275_000
      )
      expect(call[:duration]).to be_a(Integer)
    end

    it "groups by provider, model, and operation so spend tables split by model" do
      in_execution do
        emit("chat.ruby_llm", v2_chat_payload)
        emit("chat.ruby_llm", v2_chat_payload)
        emit("chat.ruby_llm", v2_chat_payload(model: "claude-haiku-4-5"))
      end

      expect(railwatch_records(:llm_call).map { |c| c[:_group] }.uniq.size).to eq(2)
    end

    it "records every usage-bearing operation, not just chat" do
      in_execution do
        emit("embedding.ruby_llm", v2_chat_payload(input: "ton"))
        emit("image.ruby_llm", v2_chat_payload(prompt: "a hopper car"))
        emit("rerank.ruby_llm", v2_chat_payload(query: "ton"))
        emit("speech.ruby_llm", v2_chat_payload)
      end

      expect(railwatch_records(:llm_call).map { |c| c[:operation] })
        .to contain_exactly("embedding", "image", "rerank", "speech")
    end

    # compaction carries the same tokens and the same cost as any other chat
    # call, and the provider bills for it. Missing it hides real spend.
    it "bills a compaction, which is a chat call the conversation made of itself" do
      in_execution { emit("compaction.ruby_llm", v2_chat_payload) }

      expect(railwatch_records(:llm_call).sole)
        .to include(operation: "compaction", cost_nanos: 4_275_000, input_tokens: 1200)
    end

    it "stamps the workflow and step so an agent run can be reassembled" do
      in_execution do
        emit("chat.ruby_llm", v2_chat_payload(
          workflow_id: "article-42", workflow_name: "Write article",
          workflow_step_id: "step-1", workflow_step_name: "Research",
          workflow_step_parent_id: "step-0"))
      end

      expect(railwatch_records(:llm_call).sole).to include(
        workflow_id: "article-42", workflow_name: "Write article",
        workflow_step_id: "step-1", workflow_step_name: "Research",
        workflow_step_parent_id: "step-0"
      )
    end

    it "leaves cost unknown rather than zero when the registry has no pricing" do
      in_execution { emit("chat.ruby_llm", v2_chat_payload(cost: Cost.new(total: nil))) }

      expect(railwatch_records(:llm_call).sole[:cost_nanos]).to be_nil
    end
  end

  describe "RubyLLM 1.16 payloads" do
    it "reads the scalar token counts the older payload carries" do
      in_execution { emit("chat.ruby_llm", v116_chat_payload) }

      expect(railwatch_records(:llm_call).sole).to include(
        operation: "chat", provider: "openai", model: "gpt-5.6", streaming: true,
        input_tokens: 800, output_tokens: 120, cache_read_tokens: 0,
        cache_write_tokens: nil, thinking_tokens: nil
      )
    end

    it "reports no cost, because 1.16 reports none -- not a cost of zero" do
      in_execution { emit("chat.ruby_llm", v116_chat_payload) }

      expect(railwatch_records(:llm_call).sole[:cost_nanos]).to be_nil
    end

    it "records no workflow columns, because 1.16 has no workflows" do
      in_execution { emit("chat.ruby_llm", v116_chat_payload) }

      expect(railwatch_records(:llm_call).sole).not_to have_key(:workflow_id)
    end
  end

  describe "tool calls" do
    it "records a tool invocation as the same record with no tokens or cost" do
      in_execution do
        emit("tool_call.ruby_llm", provider: "anthropic", model: "claude-opus-5",
                                   tool_name: "lookup_rate", tool_arguments: { lane: "CHI-DAL" },
                                   tool_call_id: "toolu_1")
      end

      call = railwatch_records(:llm_call).sole
      expect(call).to include(operation: "tool", tool_name: "lookup_rate", status: "ok")
      expect(call[:cost_nanos]).to be_nil
      expect(call[:input_tokens]).to be_nil
    end
  end

  describe "failures" do
    # Stands in for RubyLLM::RateLimitError, which this gem must not require.
    RateLimited = Class.new(StandardError)

    it "records a raised call as failed with the error, and re-raises" do
      expect do
        in_execution do
          ActiveSupport::Notifications.instrument("chat.ruby_llm", v2_chat_payload) do
            raise RateLimited, "429 slow down"
          end
        end
      end.to raise_error(RateLimited)

      expect(railwatch_records(:llm_call).sole).to include(
        status: "failed", error: "RateLimited: 429 slow down"
      )
    end
  end

  describe "content capture" do
    it "captures no prompt or completion by default" do
      in_execution { emit("chat.ruby_llm", v2_chat_payload) }

      expect(railwatch_records(:llm_call).sole).to include(prompt: nil, completion: nil)
    end

    it "captures the last user turn and the reply when the operator opts in" do
      Railwatch.config.capture_llm_content = true
      in_execution do
        emit("chat.ruby_llm", v2_chat_payload(
          response: Message.new(role: :assistant, content: "About 110 tons.")))
      end

      expect(railwatch_records(:llm_call).sole).to include(
        prompt: "How many tons?", completion: "About 110 tons."
      )
    ensure
      Railwatch.config.capture_llm_content = false
    end

    it "caps captured content in bytes, so multibyte text cannot blow the budget" do
      Railwatch.config.capture_llm_content = true
      in_execution do
        # Three bytes per character: a character cap would ship ~12 KiB here.
        emit("chat.ruby_llm", v2_chat_payload(
          input_messages: [ Message.new(role: :user, content: "積荷" * 5_000) ]))
      end

      prompt = railwatch_records(:llm_call).sole[:prompt]
      expect(prompt.bytesize).to be <= described_class::CONTENT_MAX
      expect(prompt.bytesize).to be > described_class::CONTENT_MAX - 4
      expect(prompt).to be_valid_encoding
    ensure
      Railwatch.config.capture_llm_content = false
    end
  end

  describe "gates" do
    it "counts every call on the execution so a request shows its LLM total" do
      in_execution { 3.times { emit("chat.ruby_llm", v2_chat_payload) } }

      expect(railwatch_records(:command).sole[:counters][:llm_calls]).to eq(3)
    end

    it "records nothing when llm_calls is ignored" do
      Railwatch.config.ignore = [ :llm_calls ]
      in_execution { emit("chat.ruby_llm", v2_chat_payload) }

      expect(railwatch_records(:llm_call)).to be_empty
    ensure
      Railwatch.config.ignore = []
    end

    it "records nothing outside an execution, since there is nothing to attach to" do
      emit("chat.ruby_llm", v2_chat_payload)

      expect(railwatch_records(:llm_call)).to be_empty
    end
  end
end
