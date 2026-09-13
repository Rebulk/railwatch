# frozen_string_literal: true

module Railwatch
  module Subscribers
    module Storage
      extend Base

      OPS = %w[service_upload service_download service_streaming_download service_delete
               service_delete_prefixed service_exist service_url service_update_metadata
               analyze transform preview].freeze

      module_function

      def install!(_app)
        OPS.each do |op|
          subscribe("#{op}.active_storage") do |event|
            exe = execution
            exe&.count(:storage_ops)
            next unless recording?
            p = event.payload
            service = p[:service].to_s
            Railwatch.record(:storage_op,
              group: Record.group_hash(service, op),
              timestamp: started_at(event),
              service: service,
              op: op.delete_prefix("service_"),
              key: p[:key].to_s[0, 255],
              duration: micros(event),
              exist: p[:exist])
          end
        end
      end
    end
  end
end
