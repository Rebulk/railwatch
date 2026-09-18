# frozen_string_literal: true

module Railwatch
  # Who is looking at the dashboard. The platform has accounts and memberships;
  # an embedded install sits behind the host's own authentication, so this is
  # whatever the host says it is (Railwatch.config.dashboard_user), defaulting
  # to a single anonymous operator. Comments, saved views and issue activity
  # record this id.
  class User
    ID = 1

    attr_reader :id, :name, :email

    def self.current = Viewer.user
    def self.find(id) = find_by(id: id) || raise(ActiveRecord::RecordNotFound, "User #{id}")

    # A host's dashboard_user resolver hands back its own ids, and those ids
    # are what comments, saved views and issue activity store. Resolving only
    # ID meant a comment written by user 7 had no author, and assigning an
    # issue to them raised RecordNotFound. There is no user table to look
    # anyone up in, so: the viewer when it is them, the anonymous operator
    # for the default id, and a bare identity carrying the stored id
    # otherwise, which is everything that is actually known about them.
    def self.find_by(id:)
      return nil if id.nil? || id.to_s.empty?
      viewer = Viewer.user
      return viewer if viewer && viewer.id.to_s == id.to_s
      return default if id.to_i == ID

      new(id: id, name: "Operator", email: nil)
    end

    def self.default = @default ||= new(id: ID, name: "Operator", email: nil)

    def initialize(id:, name:, email: nil)
      @id = id
      @name = name
      @email = email
    end

    def as_json(*) = { id: id, name: name, email: email, provider: nil, verified: true, editor: "vscode", editor_root: nil }
    def accounts = [ Railwatch::Embedded::Account ]
    def ==(other) = other.is_a?(User) && other.id == id
    alias eql? ==
    def hash = id.hash
  end
end
