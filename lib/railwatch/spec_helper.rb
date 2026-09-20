# frozen_string_literal: true

# Test helpers for apps using Railwatch. Add to spec/rails_helper.rb:
#   require "railwatch/spec_helper"
#   config.include Railwatch::SpecHelper
#
# `require "railwatch/rspec"` does both of those and adds the block matchers;
# `require "railwatch/minitest"` is the Minitest equivalent.
module Railwatch
  module SpecHelper
    # Raised instead of silently reporting zero records, which would turn a
    # CI performance gate into a no-op that always passes.
    class Disabled < StandardError; end

    class MemoryTransport
      attr_reader :batches
      def initialize = @batches = []
      def deliver(records, dropped: 0, batch_id: nil, **)
        @batches << records
        Transport::Http::Result.new(ok: true, status: 200, accepted: records.size, rejected: 0)
      end
      def ping = true
    end

    def railwatch_records(type = nil)
      Railwatch.flush
      all = railwatch_transport.batches.flatten
      type ? all.select { |r| r[:t] == type.to_s } : all
    end

    def railwatch_transport
      @railwatch_transport ||= begin
        transport = MemoryTransport.new
        Railwatch.instance_variable_set(:@reporter, Railwatch::Reporter.new(Railwatch.config, transport: transport))
        transport
      end
    end

    # Runs the block and returns only the records it produced. Backs every
    # matcher in railwatch/rspec and every assertion in railwatch/minitest.
    #
    # Child records sit on their execution until it finishes, so there are
    # three cases. A block that opens and closes its own execution (a request
    # spec's `get "/widgets"`) needs no help — its records reach the transport
    # by the time the block returns. A block with nothing executing (a model or
    # service spec) is wrapped in an execution here. A block running *inside*
    # an already-open execution has its records read straight off that
    # execution's buffer, since nothing will flush them until it ends.
    def railwatch_capture
      unless Railwatch.enabled?
        raise Disabled, "Railwatch is disabled (config.enabled is false or config.token is blank), " \
                        "so this block would always look empty. Set RAILWATCH_TOKEN in your test environment."
      end

      Railwatch.flush
      batch_offset = railwatch_transport.batches.size
      buffered = with_railwatch_execution { yield }
      Railwatch.flush
      railwatch_transport.batches[batch_offset..].flatten + buffered
    end

    private

    # Returns the records buffered on a pre-existing execution by the block
    # (empty when this opened its own, since finishing it ships them).
    def with_railwatch_execution
      exe = Railwatch.execution
      if exe
        offset = exe.records.size
        yield
        exe.records[offset..] || []
      else
        # :command is the closest of Execution::SOURCES to a test body.
        # Sampling is forced on so a fractional sample rate in the app's test
        # config can't quietly turn an assertion into one that never fires.
        Railwatch.start_execution(source: :command, sample_kind: :requests).sampled = true
        begin
          yield
        ensure
          # No parent type: the wrapper itself must not add a `command` record.
          Railwatch.finish_execution
        end
        []
      end
    end

    # --- shared by railwatch/rspec and railwatch/minitest -------------------------

    SQL_PREVIEW_CHARS = 120

    class << self
      # Exactly one of exactly:/at_most:/at_least: describes the bound.
      def count_satisfied?(count, exactly: nil, at_most: nil, at_least: nil)
        bound = check_bound(exactly: exactly, at_most: at_most, at_least: at_least)
        case bound.first
        when :exactly then count == bound.last
        when :at_most then count <= bound.last
        else count >= bound.last
        end
      end

      def bound_description(exactly: nil, at_most: nil, at_least: nil)
        kind, value = check_bound(exactly: exactly, at_most: at_most, at_least: at_least)
        "#{kind.to_s.tr('_', ' ')} #{value}"
      end

      # Every failure message ends in the offending records, so CI output says
      # which queries to go and fix rather than just "expected 5, got 9".
      def sql_lines(records)
        lines(records) { |r| truncate(r[:sql]) }
      end

      def n_plus_one_lines(records)
        lines(records) { |r| "#{r[:count]}x #{truncate(r[:sql])}#{" at #{r[:source]}" if r[:source]}" }
      end

      def outgoing_lines(records)
        lines(records) { |r| "#{r[:method]} #{truncate(r[:url])}" }
      end

      def exception_lines(records)
        lines(records) { |r| "#{r[:class]}: #{truncate(r[:message])}" }
      end

      def record_names(records, key)
        records.map { |r| r[key].to_s }
      end

      def truncate(value)
        value.to_s.gsub(/\s+/, " ").strip[0, SQL_PREVIEW_CHARS]
      end

      private

      def lines(records)
        return " (none)" if records.empty?
        records.each_with_index.map { |r, i| "\n  #{i + 1}. #{yield(r)}" }.join
      end

      def check_bound(exactly:, at_most:, at_least:)
        given = { exactly: exactly, at_most: at_most, at_least: at_least }.compact
        raise ArgumentError, "pass exactly one of exactly:, at_most:, at_least:" unless given.size == 1
        given.first
      end
    end
  end
end
