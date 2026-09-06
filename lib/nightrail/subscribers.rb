# frozen_string_literal: true

require "nightrail/subscribers/base"
require "nightrail/subscribers/requests"
require "nightrail/subscribers/queries"
require "nightrail/subscribers/exceptions"
require "nightrail/subscribers/cache"
require "nightrail/subscribers/mail"
require "nightrail/subscribers/broadcasts"
require "nightrail/subscribers/notifications"
require "nightrail/subscribers/storage"
require "nightrail/subscribers/views"
require "nightrail/subscribers/logs"
require "nightrail/subscribers/jobs"
require "nightrail/subscribers/deprecations"
require "nightrail/subscribers/users"
require "nightrail/subscribers/process_info"

module Nightrail
  module Subscribers
    ALL = [ Requests, Queries, Exceptions, Cache, Mail, Broadcasts, Notifications,
            Storage, Views, Logs, Jobs, Deprecations, Users, ProcessInfo ].freeze

    module_function

    def install!(app = nil)
      ALL.each do |subscriber|
        subscriber.install!(app)
      rescue StandardError => e
        Nightrail.debug { "failed to install #{subscriber.name}: #{e.class}: #{e.message}" }
      end
    end
  end
end
