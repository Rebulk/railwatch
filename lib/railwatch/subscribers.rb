# frozen_string_literal: true

require "railwatch/subscribers/base"
require "railwatch/subscribers/requests"
require "railwatch/subscribers/queries"
require "railwatch/subscribers/exceptions"
require "railwatch/subscribers/cache"
require "railwatch/subscribers/mail"
require "railwatch/subscribers/broadcasts"
require "railwatch/subscribers/notifications"
require "railwatch/subscribers/storage"
require "railwatch/subscribers/views"
require "railwatch/subscribers/logs"
require "railwatch/subscribers/jobs"
require "railwatch/subscribers/deprecations"
require "railwatch/subscribers/users"
require "railwatch/subscribers/process_info"

module Railwatch
  module Subscribers
    ALL = [ Requests, Queries, Exceptions, Cache, Mail, Broadcasts, Notifications,
            Storage, Views, Logs, Jobs, Deprecations, Users, ProcessInfo ].freeze

    module_function

    def install!(app = nil)
      ALL.each do |subscriber|
        subscriber.install!(app)
      rescue StandardError => e
        Railwatch.debug { "failed to install #{subscriber.name}: #{e.class}: #{e.message}" }
      end
    end
  end
end
