# frozen_string_literal: true

require "spec_helper"
require "action_cable/channel/test_case"

# Live dashboard updates, and the reason they were dead in a real install.
#
# The channel used to ask `connection.request`. That reads as the obvious way
# to reach the request from a channel, and Rails even documents the method --
# but it is defined below `private` in ActionCable::Connection::Base, meant for
# use inside a Connection subclass. From a channel it raises NoMethodError, so
# every subscribe failed, the client retried forever, and the dashboard showed
# "Disconnected" on every page while the data behind it was fine.
#
# Nothing caught it because there was no channel spec at all, and because
# Action Cable's own ConnectionStub defines neither `request` nor `env` -- a
# stub that happened to expose a public `request` would have agreed with the
# broken code. So this stub mirrors the real class's visibility exactly: `env`
# public, `request` private.
RSpec.describe Railwatch::EnvironmentChannel do
  # Pinned deliberately. If a future Rails makes `request` public this stops
  # being a trap, and if it stays private the channel must keep off it.
  it "is a trap worth avoiding: Connection#request is private, #env is public" do
    expect(ActionCable::Connection::Base.public_method_defined?(:request)).to be(false)
    expect(ActionCable::Connection::Base.public_method_defined?(:env)).to be(true)
  end

  let(:connection) do
    Class.new(ActionCable::Channel::ConnectionStub) do
      def initialize(env)
        super({})
        @env = env
      end

      attr_reader :env # public on ActionCable::Connection::Base

      private

      def request = ActionDispatch::Request.new(@env) # private on it, as here
    end.new(Rack::MockRequest.env_for("/cable"))
  end

  def subscribe_with(params)
    described_class.new(connection, "ident", params).tap(&:subscribe_to_channel)
  end

  around do |example|
    previous = Railwatch.config.dashboard_open
    Railwatch.config.dashboard_open = true
    example.run
  ensure
    Railwatch.config.dashboard_open = previous
  end

  it "subscribes without reaching for a private method on the connection" do
    channel = nil

    expect { channel = subscribe_with(id: Railwatch::Environment::ID) }.not_to raise_error
    expect(channel.send(:streams)).to include("environment_#{Railwatch::Environment::ID}")
  end

  it "refuses an id that is not this install's one environment" do
    expect(subscribe_with(id: 99).send(:streams)).to be_empty
  end
end
