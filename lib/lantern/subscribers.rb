# frozen_string_literal: true

require "lantern/subscribers/base"
require "lantern/subscribers/requests"
require "lantern/subscribers/queries"
require "lantern/subscribers/exceptions"
require "lantern/subscribers/cache"
require "lantern/subscribers/mail"
require "lantern/subscribers/broadcasts"
require "lantern/subscribers/notifications"
require "lantern/subscribers/storage"
require "lantern/subscribers/views"
require "lantern/subscribers/logs"
require "lantern/subscribers/jobs"
require "lantern/subscribers/deprecations"
require "lantern/subscribers/users"
require "lantern/subscribers/process_info"

module Lantern
  module Subscribers
    ALL = [ Requests, Queries, Exceptions, Cache, Mail, Broadcasts, Notifications,
            Storage, Views, Logs, Jobs, Deprecations, Users, ProcessInfo ].freeze

    module_function

    def install!(app = nil)
      ALL.each do |subscriber|
        subscriber.install!(app)
      rescue StandardError => e
        Lantern.debug { "failed to install #{subscriber.name}: #{e.class}: #{e.message}" }
      end
    end
  end
end
