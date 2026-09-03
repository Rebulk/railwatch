# frozen_string_literal: true

require "spec_helper"

# Noticed isn't installed in this gem's dependencies (see Gemfile), so
# Lantern::Subscribers::Notifications.install! never runs its
# `return unless defined?(::Noticed)` guard successfully at boot. Define a
# minimal stand-in Noticed:: delivery job and install the subscriber by hand
# to exercise it, matching how it would behave once Noticed is present.
module Noticed
end

class Noticed::TestDelivery < ActiveJob::Base
  def perform(notification_class: nil, **)
    raise "delivery failed" if notification_class == "boom"
  end
end

RSpec.describe "notification record" do
  before(:context) { Lantern::Subscribers::Notifications.install!(Rails.application) }

  def finish!
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "derives channel from the Noticed delivery class" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Noticed::TestDelivery.perform_now(notification_class: "WelcomeNotification")
    finish!
    expect(lantern_records(:notification).sole[:channel]).to eq("test")
  end

  it "captures the notifier class, delivery_method, duration, and failed false for a clean delivery" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Noticed::TestDelivery.new(notification_class: "WidgetNotifier").perform_now
    finish!

    rec = lantern_records(:notification).sole
    expect(rec[:notifier]).to eq("WidgetNotifier")
    expect(rec[:delivery_method]).to eq("TestDelivery")
    expect(rec[:duration]).to be_a(Integer).and be >= 0
    expect(rec[:failed]).to be(false)
  end

  it "reports failed true when the delivery job raises" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    expect { Noticed::TestDelivery.new(notification_class: "boom").perform_now }.to raise_error("delivery failed")
    finish!

    expect(lantern_records(:notification).sole[:failed]).to be(true)
  end

  it "never ships a notification record for an ordinary (non-Noticed::) job" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    WidgetJob.new("plain").perform_now
    finish!

    expect(lantern_records(:notification)).to be_empty
  end
end
