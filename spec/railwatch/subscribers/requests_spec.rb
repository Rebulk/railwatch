# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# An action that streams its response, run on its own thread the way a
# real server runs it (rspec-rails loads action_controller/test_case, which
# runs Live actions inline).
class StreamedWidgetsController < ActionController::Base
  include ActionController::Live

  CHUNKS = 5

  class << self
    attr_accessor :gate
  end

  def show
    response.headers["Content-Type"] = "application/octet-stream"
    response.stream.write("chunk0;")
    # The client has the first chunk and is still reading.
    self.class.gate.pop
    (1...CHUNKS).each { |i| response.stream.write("chunk#{i};") }
  ensure
    response.stream.close
  end

  private

  def new_controller_thread(&block)
    original_new_controller_thread(&block)
  end
end

# The process_action subscriber sizes Inertia props. X-Inertia on the
# request is the client's to send to any action, so the size is taken only
# from a response Inertia rendered, and never by reading a body that is a
# file or a stream.
RSpec.describe Railwatch::Subscribers::Requests do
  describe "Inertia props size", type: :request do
    it "is the size of the page object inertia_rails rendered for an Inertia visit" do
      get "/ssr_widgets", headers: { "X-Inertia" => "true" }

      expect(response.headers["X-Inertia"]).to eq("true")
      req = railwatch_records(:request).sole
      expect(req[:inertia]).to include(component: "Widgets/Index", props_bytes: response.body.bytesize)
    end

    it "does not read a sent file when the client claims to be an Inertia visit" do
      dir = Dir.mktmpdir("railwatch-send-file", ENV.fetch("TMPDIR", Dir.tmpdir))
      path = File.join(dir, "report.bin")
      File.binwrite(path, "x" * 70_000)
      allow_any_instance_of(WidgetsController).to receive(:index) do |controller|
        controller.send(:send_file, path, type: "application/octet-stream")
      end
      reads = []
      allow(File).to receive(:binread).and_wrap_original do |original, *args, **kw|
        reads << args.first.to_s
        original.call(*args, **kw)
      end

      get "/widgets", headers: { "X-Inertia" => "true" }

      expect(response).to have_http_status(:ok)
      expect(reads).not_to include(path)
      expect(railwatch_records(:request).sole[:inertia]).not_to have_key(:props_bytes)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "a streamed response" do
    let(:app) { Railwatch::Middleware::Request.new(StreamedWidgetsController.action(:show)) }
    let(:whole) { (0...StreamedWidgetsController::CHUNKS).map { |i| "chunk#{i};" }.join }

    # Reads the first chunk, lets the action write the rest, waits until
    # every process_action subscriber -- Railwatch's first, it subscribed at
    # boot -- has run for it, then reads on.
    def fetch(headers)
      StreamedWidgetsController.gate = Queue.new
      finished = Queue.new
      # One argument, like Railwatch's own subscriber, so it is called in
      # the same group and after it.
      callback = ->(_event) { finished.push(true) }
      ActiveSupport::Notifications.subscribed(callback, "process_action.action_controller") do
        status, _headers, body = app.call(Rack::MockRequest.env_for("/streamed", headers))
        received = +""
        body.each do |chunk|
          received << chunk
          next unless received == "chunk0;"

          StreamedWidgetsController.gate.push(true)
          finished.pop(timeout: 5) or raise "the action never finished"
        end
        body.close if body.respond_to?(:close)
        [ status, received ]
      end
    end

    it "reaches the client whole when the client sends X-Inertia: true" do
      expect(fetch({})).to eq([ 200, whole ])
      expect(fetch({ "HTTP_X_INERTIA" => "true" })).to eq([ 200, whole ])
    end
  end
end
