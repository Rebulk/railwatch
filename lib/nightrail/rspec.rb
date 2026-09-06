# frozen_string_literal: true

require "rspec/matchers"
require "nightrail/spec_helper"

# Block matchers over the records a block of code produces, so a spec can
# assert on query counts, N+1s, spans, exceptions, and outgoing HTTP the same
# way it asserts on anything else. Add to spec/rails_helper.rb:
#
#   require "nightrail/rspec"
#
# They work in a request spec (`expect { get "/widgets" }`) and in a plain
# model or service spec alike -- see docs/testing.md.
RSpec::Matchers.define :have_nightrail_queries do |bounds|
  supports_block_expectations

  match do |block|
    @queries = nightrail_capture(&block).select { |r| r[:t] == "query" }
    Nightrail::SpecHelper.count_satisfied?(@queries.size, **bounds)
  end

  description { "run #{Nightrail::SpecHelper.bound_description(**bounds)} database queries" }

  failure_message do
    "expected the block to run #{Nightrail::SpecHelper.bound_description(**bounds)} database queries, " \
      "but it ran #{@queries.size}:#{Nightrail::SpecHelper.sql_lines(@queries)}"
  end

  failure_message_when_negated do
    "expected the block not to run #{Nightrail::SpecHelper.bound_description(**bounds)} database queries, " \
      "but it ran #{@queries.size}:#{Nightrail::SpecHelper.sql_lines(@queries)}"
  end
end

RSpec::Matchers.define :have_nightrail_n_plus_one do
  supports_block_expectations

  match do |block|
    @n_plus_ones = nightrail_capture(&block).select { |r| r[:t] == "n_plus_one" }
    @n_plus_ones.any?
  end

  description { "trip Nightrail's N+1 detector" }

  failure_message do
    "expected the block to trip Nightrail's N+1 detector (config.n_plus_one_threshold = " \
      "#{Nightrail.config.n_plus_one_threshold}), but no n_plus_one record was produced"
  end

  failure_message_when_negated do
    "expected no N+1 queries, but #{@n_plus_ones.size} were " \
      "detected:#{Nightrail::SpecHelper.n_plus_one_lines(@n_plus_ones)}"
  end
end

RSpec::Matchers.define :record_nightrail_span do |name|
  supports_block_expectations

  match do |block|
    @spans = nightrail_capture(&block).select { |r| r[:t] == "span" }
    name ? @spans.any? { |s| s[:name] == name } : @spans.any?
  end

  description { name ? "record a #{name.inspect} span" : "record a span" }

  failure_message do
    "expected the block to record a #{name ? name.inspect : ''} span, but it recorded " \
      "#{@spans.size}: #{Nightrail::SpecHelper.record_names(@spans, :name).inspect}"
  end

  failure_message_when_negated do
    "expected the block not to record a #{name ? name.inspect : ''} span, but it recorded " \
      "#{@spans.size}: #{Nightrail::SpecHelper.record_names(@spans, :name).inspect}"
  end
end

RSpec::Matchers.define :record_nightrail_exception do |klass|
  supports_block_expectations

  match do |block|
    @exceptions = nightrail_capture(&block).select { |r| r[:t] == "exception" }
    klass ? @exceptions.any? { |e| e[:class] == klass.to_s } : @exceptions.any?
  end

  description { "record #{klass ? "a #{klass}" : 'an'} exception" }

  failure_message do
    "expected the block to record #{klass ? "a #{klass}" : 'an'} exception, but it recorded " \
      "#{@exceptions.size}:#{Nightrail::SpecHelper.exception_lines(@exceptions)}"
  end

  failure_message_when_negated do
    "expected the block not to record #{klass ? "a #{klass}" : 'an'} exception, but it recorded " \
      "#{@exceptions.size}:#{Nightrail::SpecHelper.exception_lines(@exceptions)}"
  end
end

# The negative half of record_nightrail_exception, for "this block must not
# report anything at all" -- `expect { }.not_to record_nightrail_exceptions`.
RSpec::Matchers.define :record_nightrail_exceptions do
  supports_block_expectations

  match do |block|
    @exceptions = nightrail_capture(&block).select { |r| r[:t] == "exception" }
    @exceptions.any?
  end

  description { "record at least one exception" }

  failure_message { "expected the block to record an exception, but it recorded none" }

  failure_message_when_negated do
    "expected the block to record no exceptions, but it recorded " \
      "#{@exceptions.size}:#{Nightrail::SpecHelper.exception_lines(@exceptions)}"
  end
end

RSpec::Matchers.define :have_nightrail_outgoing_requests do |bounds|
  supports_block_expectations

  match do |block|
    @outgoing = nightrail_capture(&block).select { |r| r[:t] == "outgoing_request" }
    Nightrail::SpecHelper.count_satisfied?(@outgoing.size, **bounds)
  end

  description { "make #{Nightrail::SpecHelper.bound_description(**bounds)} outgoing HTTP requests" }

  failure_message do
    "expected the block to make #{Nightrail::SpecHelper.bound_description(**bounds)} outgoing HTTP requests, " \
      "but it made #{@outgoing.size}:#{Nightrail::SpecHelper.outgoing_lines(@outgoing)}"
  end

  failure_message_when_negated do
    "expected the block not to make #{Nightrail::SpecHelper.bound_description(**bounds)} outgoing HTTP requests, " \
      "but it made #{@outgoing.size}:#{Nightrail::SpecHelper.outgoing_lines(@outgoing)}"
  end
end

RSpec.configure { |config| config.include Nightrail::SpecHelper } if defined?(RSpec.configure)
