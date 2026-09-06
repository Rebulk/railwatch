# frozen_string_literal: true

module Nightrail
  module Subscribers
    # process.action_mailer (render) and deliver.action_mailer (send).
    module Mail
      extend Base

      module_function

      def install!(_app)
        subscribe("deliver.action_mailer") do |event|
          exe = execution
          exe&.count(:mail)
          next unless recording?
          p = event.payload
          mailer = p[:mailer].to_s
          Nightrail.record(:mail,
            group: Record.group_hash(mailer),
            timestamp: started_at(event),
            mailer: mailer,
            subject: p[:subject].to_s[0, 255],
            to: Array(p[:to]).size, cc: Array(p[:cc]).size, bcc: Array(p[:bcc]).size,
            attachments: (p[:mail]&.attachments&.size rescue 0),
            delivery_method: (p[:mail]&.delivery_method&.class&.name&.demodulize rescue nil),
            perform_deliveries: p[:perform_deliveries] != false,
            duration: micros(event),
            failed: p[:exception].present?,
            message_id: p[:message_id].to_s[0, 255])
        end

        subscribe("process.action_mailer") do |event|
          next unless recording?
          p = event.payload
          Nightrail.record(:view_render, group: Record.group_hash("mailer", p[:mailer], p[:action]),
                         timestamp: started_at(event), identifier: "#{p[:mailer]}##{p[:action]}",
                         kind: "mailer", duration: micros(event))
        end
      end
    end
  end
end
