# frozen_string_literal: true

# Test helpers for apps using Lantern. Add to spec/rails_helper.rb:
#   require "lantern/spec_helper"
#   config.include Lantern::SpecHelper
module Lantern
  module SpecHelper
    class MemoryTransport
      attr_reader :batches
      def initialize = @batches = []
      def deliver(records, dropped: 0)
        @batches << records
        Transport::Http::Result.new(ok: true, status: 200, accepted: records.size, rejected: 0)
      end
      def ping = true
    end

    def lantern_records(type = nil)
      Lantern.flush
      all = lantern_transport.batches.flatten
      type ? all.select { |r| r[:t] == type.to_s } : all
    end

    def lantern_transport
      @lantern_transport ||= begin
        transport = MemoryTransport.new
        Lantern.instance_variable_set(:@reporter, Lantern::Reporter.new(Lantern.config, transport: transport))
        transport
      end
    end
  end
end
