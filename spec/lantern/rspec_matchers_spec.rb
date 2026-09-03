# frozen_string_literal: true

require "spec_helper"
require "lantern/rspec"

RSpec.describe "Lantern RSpec matchers" do
  # Every matcher runs its block through Lantern::SpecHelper#lantern_capture,
  # so a helper that raises the same way `expect { }.to matcher` would lets
  # these specs assert on the failure message text itself.
  def failure_from(matcher, &block)
    expect(&block).to matcher
    nil
  rescue RSpec::Expectations::ExpectationNotMetError => e
    e.message
  end

  def negated_failure_from(matcher, &block)
    expect(&block).not_to matcher
    nil
  rescue RSpec::Expectations::ExpectationNotMetError => e
    e.message
  end

  def record_span(name)
    Lantern.record(:span, name: name, duration: 1, attributes: {}, status: "ok")
  end

  describe "have_lantern_queries" do
    it "counts the queries a block runs when nothing else is executing" do
      expect { Widget.count }.to have_lantern_queries(exactly: 1)
    end

    it "satisfies an at_most bound that the block stays under" do
      expect { Widget.count }.to have_lantern_queries(at_most: 5)
    end

    it "satisfies an at_least bound that the block clears" do
      expect { 3.times { Widget.count } }.to have_lantern_queries(at_least: 3)
    end

    it "counts zero for a block that touches no database" do
      expect { 1 + 1 }.to have_lantern_queries(exactly: 0)
    end

    it "fails with the offending SQL when the block runs more queries than allowed" do
      message = failure_from(have_lantern_queries(at_most: 1)) { 3.times { Widget.count } }

      expect(message).to include("expected the block to run at most 1 database queries, but it ran 3")
      expect(message).to include("1. SELECT COUNT(*)")
      expect(message.lines.size).to eq(4) # headline plus one line per query
    end

    it "truncates each listed statement to 120 characters so CI output stays readable" do
      names = Array.new(60) { |i| "name-#{i}" }
      message = failure_from(have_lantern_queries(exactly: 0)) { Widget.where(name: names).to_a }

      sql_line = message.lines.last.strip.sub(/\A1\. /, "")
      expect(sql_line.length).to eq(120)
    end

    it "reports the count in the negated failure message too" do
      message = negated_failure_from(have_lantern_queries(at_most: 5)) { Widget.count }

      expect(message).to include("expected the block not to run at most 5 database queries, but it ran 1")
    end

    it "counts queries a request spec's own execution produced" do
      expect { Widget.count }.to have_lantern_queries(at_least: 1)
    end

    it "rejects being given more than one bound" do
      expect { expect { Widget.count }.to have_lantern_queries(at_most: 1, at_least: 1) }
        .to raise_error(ArgumentError, /exactly one of/)
    end

    it "rejects being given no bound at all" do
      expect { expect { Widget.count }.to have_lantern_queries({}) }
        .to raise_error(ArgumentError, /exactly one of/)
    end

    it "describes itself in terms of the bound" do
      expect(have_lantern_queries(at_most: 5).description).to eq("run at most 5 database queries")
    end
  end

  describe "have_lantern_n_plus_one" do
    around do |example|
      Lantern.config.n_plus_one_threshold = 3
      example.run
      Lantern.config.n_plus_one_threshold = 5
    end

    it "passes when a block repeats one query shape past the threshold" do
      Widget.create!(name: "w", gadget: Gadget.create!(name: "g"))

      expect { 4.times { |i| Widget.where(id: i).to_a } }.to have_lantern_n_plus_one
    end

    it "passes the negated form for a block with no repeated query shape" do
      expect { Widget.count }.not_to have_lantern_n_plus_one
    end

    it "lists the repeated statement, count, and source in the negated failure message" do
      message = negated_failure_from(have_lantern_n_plus_one) { 4.times { |i| Widget.where(id: i).to_a } }

      expect(message).to include("expected no N+1 queries, but 1 were detected")
      expect(message).to include("3x SELECT")
      expect(message).to include('"widgets"')
    end

    it "names the configured threshold in the positive failure message" do
      message = failure_from(have_lantern_n_plus_one) { Widget.count }

      expect(message).to include("config.n_plus_one_threshold = 3")
      expect(message).to include("no n_plus_one record was produced")
    end
  end

  describe "record_lantern_span" do
    it "passes when the block records a span with that name" do
      expect { record_span("checkout.total") }.to record_lantern_span("checkout.total")
    end

    it "passes with no name for any span at all" do
      expect { record_span("anything") }.to record_lantern_span(nil)
    end

    it "does not match a span recorded under a different name" do
      expect { record_span("checkout.tax") }.not_to record_lantern_span("checkout.total")
    end

    it "lists the span names that were recorded when none matched" do
      message = failure_from(record_lantern_span("checkout.total")) { record_span("checkout.tax") }

      expect(message).to include('expected the block to record a "checkout.total" span')
      expect(message).to include('["checkout.tax"]')
    end
  end

  describe "record_lantern_exception" do
    it "passes when the block reports an exception of that class" do
      expect { Lantern.report(ArgumentError.new("boom")) }.to record_lantern_exception(ArgumentError)
    end

    it "does not match a different exception class" do
      expect { Lantern.report(ArgumentError.new("boom")) }.not_to record_lantern_exception(TypeError)
    end

    it "lists the exceptions that were recorded when the class did not match" do
      message = failure_from(record_lantern_exception(TypeError)) { Lantern.report(ArgumentError.new("boom")) }

      expect(message).to include("expected the block to record a TypeError exception, but it recorded 1")
      expect(message).to include("ArgumentError: boom")
    end
  end

  describe "record_lantern_exceptions" do
    it "passes the negated form for a block that reports nothing" do
      expect { Widget.count }.not_to record_lantern_exceptions
    end

    it "lists every recorded exception in the negated failure message" do
      message = negated_failure_from(record_lantern_exceptions) do
        Lantern.report(ArgumentError.new("first"))
        Lantern.report(TypeError.new("second"))
      end

      expect(message).to include("expected the block to record no exceptions, but it recorded 2")
      expect(message).to include("ArgumentError: first")
      expect(message).to include("TypeError: second")
    end
  end

  describe "have_lantern_outgoing_requests" do
    it "counts outgoing HTTP a block makes" do
      expect { Net::HTTP.get(URI("http://example.test/one")) }.to have_lantern_outgoing_requests(exactly: 1)
    end

    it "counts zero for a block that makes none" do
      expect { Widget.count }.to have_lantern_outgoing_requests(at_most: 0)
    end

    it "lists the method and url of each request when the bound is exceeded" do
      message = failure_from(have_lantern_outgoing_requests(at_most: 1)) do
        2.times { |i| Net::HTTP.get(URI("http://example.test/#{i}")) }
      end

      expect(message).to include("expected the block to make at most 1 outgoing HTTP requests, but it made 2")
      expect(message).to include("GET http://example.test/0")
      expect(message).to include("GET http://example.test/1")
    end
  end

  describe "capture mechanics" do
    it "ignores records produced before the block runs" do
      Widget.count

      expect { 1 + 1 }.to have_lantern_queries(exactly: 0)
    end

    it "reads records off an already-open execution rather than waiting for it to finish" do
      Lantern.start_execution(source: :request).sampled = true
      begin
        expect { Widget.count }.to have_lantern_queries(exactly: 1)
        expect(Lantern.execution.source).to eq(:request)
      ensure
        Lantern.finish_execution
      end
    end

    it "does not leave an execution open after wrapping a block in one" do
      expect { Widget.count }.to have_lantern_queries(exactly: 1)

      expect(Lantern.execution).to be_nil
    end

    it "adds no command record of its own for the execution it opened" do
      expect { Widget.count }.to have_lantern_queries(exactly: 1)

      expect(lantern_records(:command)).to be_empty
    end

    it "closes the execution it opened even when the block raises" do
      expect { expect { raise "nope" }.to have_lantern_queries(exactly: 0) }.to raise_error("nope")

      expect(Lantern.execution).to be_nil
    end

    it "raises rather than silently reporting an empty block when Lantern is disabled" do
      old_token = Lantern.config.token
      Lantern.config.token = nil

      expect { expect { Widget.count }.to have_lantern_queries(exactly: 0) }
        .to raise_error(Lantern::SpecHelper::Disabled, /Set LANTERN_TOKEN/)
    ensure
      Lantern.config.token = old_token
    end

    it "measures the block even when the app's request sample rate is zero" do
      Lantern.config.sample = Lantern.config.sample.merge(requests: 0.0)

      expect { Widget.count }.to have_lantern_queries(exactly: 1)
    end
  end
end

RSpec.describe "Lantern RSpec matchers in a request spec", type: :request do
  it "counts the queries a whole request ran" do
    Widget.create!(name: "w", gadget: Gadget.create!(name: "g"))

    expect { get "/widgets" }.to have_lantern_queries(at_least: 1)
  end

  it "sees the outgoing HTTP a controller action made" do
    expect { get "/outbound" }.to have_lantern_outgoing_requests(exactly: 1)
  end
end
