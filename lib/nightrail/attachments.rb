# frozen_string_literal: true

require "base64"
require "pathname"
require "zlib"

module Nightrail
  # Nightrail.attach: ship an arbitrary blob -- the JSON payload that failed to
  # parse, a rendered PDF, the webhook body a customer swears they sent -- as
  # its own `attachment` record. Sentry's `Sentry.add_attachment` equivalent,
  # except an attachment is a first-class record linked to the execution it
  # was made in, and optionally to the exception it explains.
  #
  #   Nightrail.attach("payload.json", request.raw_post)
  #   Nightrail.attach("invoice.pdf", Rails.root.join("tmp/invoice.pdf"))
  #   Nightrail.attach("payload.json", body, exception: error)
  #
  # The wire field `data` is base64 of gzip, so a text payload costs a
  # fraction of its size in the batch.
  module Attachments
    DEFAULT_CONTENT_TYPE = "application/octet-stream"
    MAX_NAME = 255
    MAX_CONTENT_TYPE = 128

    module_function

    def attach(name, data, content_type: nil, exception: nil)
      return nil unless Nightrail.enabled?

      # cap + 1 so "was it truncated?" is still answerable without ever
      # holding more than the cap in memory. A 2GB log file used to be read
      # whole and then sliced.
      cap = Nightrail.config.max_attachment_bytes
      bytes = read(data, cap + 1)
      return nil if bytes.nil? || bytes.empty?

      name = name.to_s[0, MAX_NAME]
      truncated = bytes.bytesize > cap
      bytes = bytes.byteslice(0, cap) if truncated

      fields = {
        name: name,
        content_type: (content_type || content_type_for(name)).to_s[0, MAX_CONTENT_TYPE],
        bytes: bytes.bytesize,
        data: Base64.strict_encode64(Zlib.gzip(bytes)),
        exception_group_hash: exception && Subscribers::Exceptions.group_for(exception)
      }
      fields[:truncated] = true if truncated
      # `attachment` is in Nightrail::STANDALONE_TYPES, so this buffers as a
      # child of the current execution when one is recording and ships on its
      # own (from a boot hook, a console, a rescue with nothing executing)
      # when there isn't one.
      Nightrail.record(:attachment, group: Record.group_hash(name), **fields)
    end

    # A String is the data itself; a Pathname is a file to read; anything else
    # that responds to #read (File, StringIO, an uploaded file) is read.
    def read(data, limit)
      case data
      when nil then nil
      when String then data.byteslice(0, limit)
      when Pathname then File.binread(data, limit)
      else
        value = data.respond_to?(:read) ? data.read(limit) : data.to_s
        value.to_s.byteslice(0, limit)
      end
    rescue StandardError => e
      Nightrail.debug { "attachment read failed: #{e.class}: #{e.message}" }
      nil
    end

    # Marcel comes with Rails (Active Storage depends on it), but Nightrail's
    # only declared dependency is rails itself, so an app that has somehow
    # dropped it still attaches -- just with the generic type.
    def content_type_for(name)
      return DEFAULT_CONTENT_TYPE unless defined?(::Marcel::MimeType)

      ::Marcel::MimeType.for(name: name) || DEFAULT_CONTENT_TYPE
    rescue StandardError
      DEFAULT_CONTENT_TYPE
    end
  end
end
