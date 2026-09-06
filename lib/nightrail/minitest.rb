# frozen_string_literal: true

require "nightrail/spec_helper"

module Nightrail
  # The Minitest half of nightrail/rspec: the same block assertions, phrased as
  # assert_/refute_. Add to test/test_helper.rb:
  #
  #   require "nightrail/minitest"
  #   class ActiveSupport::TestCase
  #     include Nightrail::Minitest
  #   end
  #
  # Includes Nightrail::SpecHelper, so `nightrail_records(:query)` is available
  # too. See docs/testing.md.
  module Minitest
    include SpecHelper

    # assert_nightrail_queries(at_most: 5) { Order.find(id).total }
    # Also takes exactly: or at_least:.
    def assert_nightrail_queries(exactly: nil, at_most: nil, at_least: nil, &block)
      bounds = { exactly: exactly, at_most: at_most, at_least: at_least }
      queries = nightrail_capture(&block).select { |r| r[:t] == "query" }
      assert SpecHelper.count_satisfied?(queries.size, **bounds),
             "Expected the block to run #{SpecHelper.bound_description(**bounds)} database queries, " \
             "but it ran #{queries.size}:#{SpecHelper.sql_lines(queries)}"
    end

    def refute_nightrail_n_plus_one(&block)
      n_plus_ones = nightrail_capture(&block).select { |r| r[:t] == "n_plus_one" }
      assert n_plus_ones.empty?,
             "Expected no N+1 queries, but #{n_plus_ones.size} were " \
             "detected:#{SpecHelper.n_plus_one_lines(n_plus_ones)}"
    end

    def assert_nightrail_span(name, &block)
      spans = nightrail_capture(&block).select { |r| r[:t] == "span" }
      assert spans.any? { |s| s[:name] == name },
             "Expected the block to record a #{name.inspect} span, but it recorded " \
             "#{spans.size}: #{SpecHelper.record_names(spans, :name).inspect}"
    end
  end
end
