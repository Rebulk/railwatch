# frozen_string_literal: true

require "lantern/spec_helper"

module Lantern
  # The Minitest half of lantern/rspec: the same block assertions, phrased as
  # assert_/refute_. Add to test/test_helper.rb:
  #
  #   require "lantern/minitest"
  #   class ActiveSupport::TestCase
  #     include Lantern::Minitest
  #   end
  #
  # Includes Lantern::SpecHelper, so `lantern_records(:query)` is available
  # too. See docs/testing.md.
  module Minitest
    include SpecHelper

    # assert_lantern_queries(at_most: 5) { Order.find(id).total }
    # Also takes exactly: or at_least:.
    def assert_lantern_queries(exactly: nil, at_most: nil, at_least: nil, &block)
      bounds = { exactly: exactly, at_most: at_most, at_least: at_least }
      queries = lantern_capture(&block).select { |r| r[:t] == "query" }
      assert SpecHelper.count_satisfied?(queries.size, **bounds),
             "Expected the block to run #{SpecHelper.bound_description(**bounds)} database queries, " \
             "but it ran #{queries.size}:#{SpecHelper.sql_lines(queries)}"
    end

    def refute_lantern_n_plus_one(&block)
      n_plus_ones = lantern_capture(&block).select { |r| r[:t] == "n_plus_one" }
      assert n_plus_ones.empty?,
             "Expected no N+1 queries, but #{n_plus_ones.size} were " \
             "detected:#{SpecHelper.n_plus_one_lines(n_plus_ones)}"
    end

    def assert_lantern_span(name, &block)
      spans = lantern_capture(&block).select { |r| r[:t] == "span" }
      assert spans.any? { |s| s[:name] == name },
             "Expected the block to record a #{name.inspect} span, but it recorded " \
             "#{spans.size}: #{SpecHelper.record_names(spans, :name).inspect}"
    end
  end
end
