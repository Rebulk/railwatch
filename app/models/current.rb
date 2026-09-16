# frozen_string_literal: true

# Request-scoped attributes the platform's models read. The engine sets
# `user` from the host's dashboard_user resolver on every dashboard request.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :environment, :account

  def account = Railwatch::Embedded::Account
end
