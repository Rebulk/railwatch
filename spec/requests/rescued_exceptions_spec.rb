# frozen_string_literal: true

require "spec_helper"

# An exception a controller swallows with `rescue_from` never reaches
# Rails.error and never escapes to Railwatch's Rack middleware, so before
# capture_rescued_exceptions it produced no exception record at all -- the
# request just looked like a normal 422. Sentry calls this
# report_rescued_exceptions.
RSpec.describe "rescued exceptions", type: :request do
  it "captures a rescue_from-handled exception as a handled warning" do
    get "/rescued"
    expect(response).to have_http_status(:unprocessable_content)

    ex = railwatch_records(:exception).sole
    expect(ex[:class]).to eq("RescuedController::Boom")
    expect(ex[:message]).to eq("rescued by the controller")
    expect(ex[:handled]).to be(true)
    expect(ex[:severity]).to eq("warning")
    expect(ex[:source]).to eq("action_controller.rescue_from")
    expect(ex[:file]).to include("rescued_controller.rb")
  end

  it "still ships the request record, which reports the rescued status" do
    get "/rescued"

    request_record = railwatch_records(:request).sole
    expect(request_record[:status_code]).to eq(422)
  end

  it "captures nothing when capture_rescued_exceptions is off" do
    Railwatch.config.capture_rescued_exceptions = false
    get "/rescued"
    expect(railwatch_records(:exception)).to be_empty
  ensure
    Railwatch.config.capture_rescued_exceptions = true
  end

  it "does not capture a rescued exception whose class is in ignored_exceptions" do
    original = Railwatch.config.ignored_exceptions
    Railwatch.config.ignored_exceptions = original + [ "RescuedController::Boom" ]
    get "/rescued"
    expect(railwatch_records(:exception)).to be_empty
  ensure
    Railwatch.config.ignored_exceptions = original
  end
end
