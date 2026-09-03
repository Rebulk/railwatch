# frozen_string_literal: true

require "spec_helper"

RSpec.describe "mail record", type: :request do
  it "captures mailer, subject, recipient counts, delivery_method, perform_deliveries, duration, failed, and message_id" do
    get "/mail" # triggers WidgetMailer.notify("a@example.com").deliver_now

    mail = lantern_records(:mail).sole
    expect(mail[:mailer]).to eq("WidgetMailer")
    expect(mail[:subject]).to eq("Widget ready")
    expect(mail[:to]).to eq(1)
    expect(mail[:cc]).to eq(0)
    expect(mail[:bcc]).to eq(0)
    expect(mail[:attachments]).to eq(0)
    # Mail::Message#delivery_method is nil here even though config.action_mailer.delivery_method
    # is :test -- ActionMailer tracks the delivery method on the MessageDelivery wrapper, not on
    # the underlying Mail::Message the deliver.action_mailer event payload exposes as :mail.
    expect(mail[:delivery_method]).to be_nil
    expect(mail[:perform_deliveries]).to be(true)
    expect(mail[:duration]).to be_a(Integer).and be >= 0
    expect(mail[:failed]).to be(false)
    expect(mail[:message_id]).to match(/@.+\.mail\z/)
  end

  it "emits a mailer-kind view_render for the mailer action itself, and a template-kind view_render for the body" do
    get "/mail"

    renders = lantern_records(:view_render)
    action = renders.find { |r| r[:kind] == "mailer" }
    expect(action[:identifier]).to eq("WidgetMailer#notify")
    expect(action[:duration]).to be_a(Integer).and be >= 0

    template = renders.find { |r| r[:kind] == "template" && r[:identifier].to_s.include?("text") }
    expect(template).not_to be_nil
    expect(template[:duration]).to be_a(Integer).and be >= 0
  end
end
