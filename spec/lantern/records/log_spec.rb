# frozen_string_literal: true

require "spec_helper"

RSpec.describe "log record" do
  def finish!
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "captures level and message for a plain Rails.logger call" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info("hello world")
    finish!

    log = lantern_records(:log).sole
    expect(log[:level]).to eq("info")
    expect(log[:message]).to eq("hello world")
  end

  it "drops lines below config.log_level and keeps lines at or above it" do
    old_log_level = Lantern.config.log_level
    Lantern.config.log_level = "warn"
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info("should be dropped")
    Rails.logger.warn("should be kept")
    finish!

    expect(lantern_records(:log).map { |r| r[:message] }).to eq([ "should be kept" ])
  ensure
    Lantern.config.log_level = old_log_level
  end

  it "strips ANSI color codes and captures current_tags when the logger supports tagged logging" do
    Rails.logger.define_singleton_method(:current_tags) { [ "req-1" ] }
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info("\e[31mcolored\e[0m text")
    finish!

    log = lantern_records(:log).sole
    expect(log[:message]).to eq("colored text")
    expect(log[:tags]).to eq([ "req-1" ])
  ensure
    Rails.logger.singleton_class.send(:remove_method, :current_tags) rescue nil
  end

  it "drops Rails' own framework noise lines (Started/Completed/etc.) but keeps real app lines" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Rails.logger.info('Started GET "/widgets" for 127.0.0.1')
    Rails.logger.info("Completed 200 OK in 5ms")
    Rails.logger.info("a real app line")
    finish!

    expect(lantern_records(:log).map { |r| r[:message] }).to eq([ "a real app line" ])
  end

  it "captures a Rails.event structured event with level event, JSON context, and a source location" do
    skip "Rails.event was introduced in Rails 8.1" unless Rails.respond_to?(:event)

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Rails.event.notify("widget.custom", foo: "bar")
    finish!

    log = lantern_records(:log).find { |r| r[:message] == "widget.custom" }
    expect(log[:level]).to eq("event")
    expect(log[:context]).to eq('{"foo":"bar"}')
    expect(log[:source]).to match(%r{log_spec\.rb:\d+\z})
  end

  it "drops framework structured events (active_record., action_controller., etc.) unless capture_framework_events is enabled" do
    skip "Rails.event was introduced in Rails 8.1" unless Rails.respond_to?(:event)

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Rails.event.notify("active_record.sql", sql: "SELECT 1")
    finish!

    expect(lantern_records(:log).map { |r| r[:message] }).not_to include("active_record.sql")
  end
end
