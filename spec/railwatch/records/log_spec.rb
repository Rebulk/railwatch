# frozen_string_literal: true

require "spec_helper"

RSpec.describe "log record" do
  def finish!
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "captures level and message for a plain Rails.logger call" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info("hello world")
    finish!

    log = railwatch_records(:log).sole
    expect(log[:level]).to eq("info")
    expect(log[:message]).to eq("hello world")
  end

  it "does not make Rails.logger.debug? true just by being attached to the broadcast logger" do
    # BroadcastLogger#debug? is true when any broadcast is at DEBUG, and
    # every framework LogSubscriber (Active Record's SQL line, Action
    # View's render lines) formats its message only when it is. A Capture
    # left at DEBUG would make the app pay for log lines nobody stores.
    capture = Rails.logger.broadcasts.find { |l| l.is_a?(Railwatch::Subscribers::Logs::Capture) }
    expect(capture).not_to be_nil
    expect(capture.level).to eq(::Logger::INFO)
    expect(Rails.logger.debug?).to be(false)
  end

  it "honours Rails.logger.level= like any other broadcast, so a save-and-restore round-trips" do
    # BroadcastLogger#level is the minimum over its broadcasts and #level=
    # is dispatched to all of them. A capture that reported one level and
    # ignored assignment would make `saved = Rails.logger.level;
    # Rails.logger.level = FATAL; ...; Rails.logger.level = saved` restore
    # the app's logger to the capture's level instead of its own.
    capture = Rails.logger.broadcasts.find { |l| l.is_a?(Railwatch::Subscribers::Logs::Capture) }
    saved = Rails.logger.level
    Rails.logger.level = ::Logger::ERROR
    expect(capture.level).to eq(::Logger::ERROR)
    expect(Rails.logger.level).to eq(::Logger::ERROR)

    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info("below the level the app set")
    Rails.logger.error("at it")
    finish!

    expect(railwatch_records(:log).map { |l| l[:level] }).to eq([ "error" ])
  ensure
    Rails.logger.level = saved
  end

  it "drops lines below config.log_level and keeps lines at or above it" do
    old_log_level = Railwatch.config.log_level
    Railwatch.config.log_level = "warn"
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info("should be dropped")
    Rails.logger.warn("should be kept")
    finish!

    expect(railwatch_records(:log).map { |r| r[:message] }).to eq([ "should be kept" ])
  ensure
    Railwatch.config.log_level = old_log_level
  end

  it "strips ANSI color codes and captures current_tags when the logger supports tagged logging" do
    Rails.logger.define_singleton_method(:current_tags) { [ "req-1" ] }
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info("\e[31mcolored\e[0m text")
    finish!

    log = railwatch_records(:log).sole
    expect(log[:message]).to eq("colored text")
    expect(log[:tags]).to eq([ "req-1" ])
  ensure
    Rails.logger.singleton_class.send(:remove_method, :current_tags) rescue nil
  end

  it "drops Rails' own framework noise lines (Started/Completed/etc.) but keeps real app lines" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info('Started GET "/widgets" for 127.0.0.1')
    Rails.logger.info("Completed 200 OK in 5ms")
    Rails.logger.info("a real app line")
    finish!

    expect(railwatch_records(:log).map { |r| r[:message] }).to eq([ "a real app line" ])
  end

  it "captures a Rails.event structured event with level event, JSON context, and a source location" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Rails.event.notify("widget.custom", foo: "bar")
    finish!

    log = railwatch_records(:log).find { |r| r[:message] == "widget.custom" }
    expect(log[:level]).to eq("event")
    expect(log[:context]).to eq('{"foo":"bar"}')
    expect(log[:source]).to match(%r{log_spec\.rb:\d+\z})
  end

  it "drops framework structured events (active_record., action_controller., etc.) unless capture_framework_events is enabled" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Rails.event.notify("active_record.sql", sql: "SELECT 1")
    finish!

    expect(railwatch_records(:log).map { |r| r[:message] }).not_to include("active_record.sql")
  end
end
