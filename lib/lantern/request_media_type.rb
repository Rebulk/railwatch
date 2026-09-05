# frozen_string_literal: true

module Lantern
  # Raw Rack CONTENT_TYPE checks shared by the controller subscriber and the
  # outer request middleware. Media types are case-insensitive; parameters
  # follow the first semicolon and are not part of the type comparison.
  module RequestMediaType
    module_function

    def multipart_form_data?(content_type)
      type, = content_type.to_s.split(";", 2)
      type.strip.casecmp?("multipart/form-data")
    rescue StandardError
      false
    end
  end
end
