# frozen_string_literal: true

module Railwatch
  # Process-local state for the embedded (in-process) mode and the stand-ins
  # the telemetry code expects from the platform's primary models.
  module Embedded
    # Relation-shaped empty set for the platform associations an embedded
    # install does not have yet (issues, deploys). Every scope returns itself.
    NONE = Class.new do
      def method_missing(*) = self
      def respond_to_missing?(*) = true
      def to_a = []
      def each(&) = [].each(&)
      def first = nil
      def map(&) = []
      def count = 0
      def limit(*) = self
      def between(*) = self
      def recent = self
      def open = self
    end.new.freeze

    class << self
      attr_accessor :last_seen_at
    end
  end
end
