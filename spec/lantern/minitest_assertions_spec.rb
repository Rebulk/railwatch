# frozen_string_literal: true

require "spec_helper"
require "lantern/minitest"

# Lantern::Minitest only needs `assert` from Minitest::Test, so this stands in
# for one and records what it was asked to assert -- letting these specs check
# the failure message a real Minitest run would print.
class FakeMinitestContext
  include Lantern::Minitest

  Assertion = Struct.new(:passed, :message)

  attr_reader :assertions

  def initialize(transport)
    @lantern_transport = transport
    @assertions = []
  end

  def assert(value, message = nil)
    @assertions << Assertion.new(!!value, message)
    value
  end

  def last = @assertions.last
end

RSpec.describe "Lantern Minitest assertions" do
  subject(:test_case) { FakeMinitestContext.new(lantern_transport) }

  def record_span(name)
    Lantern.record(:span, name: name, duration: 1, attributes: {}, status: "ok")
  end

  describe "#assert_lantern_queries" do
    it "asserts true when the block stays within an at_most bound" do
      test_case.assert_lantern_queries(at_most: 5) { Widget.count }

      expect(test_case.last.passed).to be(true)
    end

    it "asserts false with the offending SQL when the block runs too many queries" do
      test_case.assert_lantern_queries(at_most: 1) { 3.times { Widget.count } }

      expect(test_case.last.passed).to be(false)
      expect(test_case.last.message).to include("Expected the block to run at most 1 database queries, but it ran 3")
      expect(test_case.last.message).to include("1. SELECT COUNT(*)")
    end

    it "supports an exactly bound" do
      test_case.assert_lantern_queries(exactly: 1) { Widget.count }

      expect(test_case.last.passed).to be(true)
    end

    it "supports an at_least bound" do
      test_case.assert_lantern_queries(at_least: 2) { 2.times { Widget.count } }

      expect(test_case.last.passed).to be(true)
    end

    it "fails an at_least bound the block does not clear" do
      test_case.assert_lantern_queries(at_least: 5) { Widget.count }

      expect(test_case.last.passed).to be(false)
      expect(test_case.last.message).to include("at least 5 database queries, but it ran 1")
    end

    it "rejects being given more than one bound" do
      expect { test_case.assert_lantern_queries(at_most: 1, exactly: 1) { Widget.count } }
        .to raise_error(ArgumentError, /exactly one of/)
    end

    it "rejects being given no bound at all" do
      expect { test_case.assert_lantern_queries { Widget.count } }
        .to raise_error(ArgumentError, /exactly one of/)
    end
  end

  describe "#refute_lantern_n_plus_one" do
    around do |example|
      Lantern.config.n_plus_one_threshold = 3
      example.run
      Lantern.config.n_plus_one_threshold = 5
    end

    it "asserts true for a block with no repeated query shape" do
      test_case.refute_lantern_n_plus_one { Widget.count }

      expect(test_case.last.passed).to be(true)
    end

    it "asserts false and lists the repeated statement when the detector trips" do
      test_case.refute_lantern_n_plus_one { 4.times { |i| Widget.where(id: i).to_a } }

      expect(test_case.last.passed).to be(false)
      expect(test_case.last.message).to include("Expected no N+1 queries, but 1 were detected")
      expect(test_case.last.message).to include("3x SELECT")
    end
  end

  describe "#assert_lantern_span" do
    it "asserts true when the block records a span with that name" do
      test_case.assert_lantern_span("checkout.total") { record_span("checkout.total") }

      expect(test_case.last.passed).to be(true)
    end

    it "asserts false and lists the recorded span names when none matched" do
      test_case.assert_lantern_span("checkout.total") { record_span("checkout.tax") }

      expect(test_case.last.passed).to be(false)
      expect(test_case.last.message).to include('Expected the block to record a "checkout.total" span')
      expect(test_case.last.message).to include('["checkout.tax"]')
    end
  end

  it "includes Lantern::SpecHelper so lantern_records is available in a Minitest case too" do
    test_case.assert_lantern_queries(exactly: 1) { Widget.count }

    expect(test_case.lantern_records(:query).size).to eq(1)
  end

  it "raises rather than asserting on an empty block when Lantern is disabled" do
    old_token = Lantern.config.token
    Lantern.config.token = nil

    expect { test_case.assert_lantern_queries(at_most: 0) { Widget.count } }
      .to raise_error(Lantern::SpecHelper::Disabled)
  ensure
    Lantern.config.token = old_token
  end
end
