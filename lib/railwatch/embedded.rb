# frozen_string_literal: true

module Railwatch
  # Process-local state for the embedded (in-process) mode and the stand-ins
  # the platform's code expects from its account layer.
  module Embedded
    # Relation-shaped empty set for platform associations an embedded install
    # does not have (Linear links, integrations). Every scope returns itself.
    NONE = Class.new do
      def method_missing(*) = self
      def respond_to_missing?(*) = true
      def to_a = []
      def each(&) = [].each(&)
      def first = nil
      def map(&) = []
      def count = 0
      def any? = false
      def none? = true
      def exists?(*) = false
      def empty? = true
      def limit(*) = self
      def where(*) = self
      def find_each(&) = nil
    end.new.freeze

    # The platform scopes everything by account (plan, quota, retention,
    # members). One embedded install is one account with none of that.
    module Account
      module_function

      def id = 1
      def name = Rails.application.class.module_parent_name
      def slug = name.parameterize
      def plan = "embedded"
      def retention_days = Railwatch.config.retention_days
      def auto_resolve_after_days = 14
      # Whoever the host's resolver named for this request, not the anonymous
      # placeholder: an embedded install has no member list, so the account's
      # one "member" is the person looking at it.
      def users = [ User.current || User.default ]
      def members = users
      def memberships = NONE
      def integrations = NONE
      def applications = [ Application.current ]
      def environments = [ Environment.current ]
      def quota_exhausted? = false
      def as_json(*) = { id: id, name: name, slug: slug, plan: plan }
    end

    class << self
      attr_accessor :last_seen_at
    end
  end
end
