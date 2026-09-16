# frozen_string_literal: true

module Railwatch
  # Who is looking at the dashboard, request-scoped. The platform's code
  # reads Current.user; the gem's own Railwatch::Current is the running
  # execution, so this has a different name. Set from the host's
  # dashboard_user resolver on every dashboard request.
  class Viewer < ActiveSupport::CurrentAttributes
    attribute :user, :environment, :account

    def account = Railwatch::Embedded::Account
  end
end
