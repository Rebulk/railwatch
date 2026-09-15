# frozen_string_literal: true

require "railwatch/spec_helper"

module Railwatch
  # The Minitest half of railwatch/rspec: the same block assertions, phrased as
  # assert_/refute_. Add to test/test_helper.rb:
  #
  #   require "railwatch/minitest"
  #
  # That includes the module into ActiveSupport::TestCase (through its load
  # hook, so the require order against rails/test_help does not matter).
  # Includes Railwatch::SpecHelper, so `railwatch_records(:query)` is available
  # too. See docs/testing.md.
  module Minitest
    include SpecHelper

    # assert_railwatch_queries(at_most: 5) { Order.find(id).total }
    # Also takes exactly: or at_least:.
    def assert_railwatch_queries(exactly: nil, at_most: nil, at_least: nil, &block)
      bounds = { exactly: exactly, at_most: at_most, at_least: at_least }
      queries = railwatch_capture(&block).select { |r| r[:t] == "query" }
      assert SpecHelper.count_satisfied?(queries.size, **bounds),
             "Expected the block to run #{SpecHelper.bound_description(**bounds)} database queries, " \
             "but it ran #{queries.size}:#{SpecHelper.sql_lines(queries)}"
    end

    def refute_railwatch_n_plus_one(&block)
      n_plus_ones = railwatch_capture(&block).select { |r| r[:t] == "n_plus_one" }
      assert n_plus_ones.empty?,
             "Expected no N+1 queries, but #{n_plus_ones.size} were " \
             "detected:#{SpecHelper.n_plus_one_lines(n_plus_ones)}"
    end

    def assert_railwatch_span(name, &block)
      spans = railwatch_capture(&block).select { |r| r[:t] == "span" }
      assert spans.any? { |s| s[:name] == name },
             "Expected the block to record a #{name.inspect} span, but it recorded " \
             "#{spans.size}: #{SpecHelper.record_names(spans, :name).inspect}"
    end
  end
end

ActiveSupport.on_load(:active_support_test_case) { include Railwatch::Minitest } if defined?(ActiveSupport.on_load)
