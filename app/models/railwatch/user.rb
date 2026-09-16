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
    def self.find(id) = id.to_i == ID ? default : raise(ActiveRecord::RecordNotFound, "User #{id}")
    def self.find_by(id:) = id.to_i == ID ? default : nil
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
