# frozen_string_literal: true

module Lantern
  # Extracts upload metadata from parameter trees without trusting their shape
  # or size. Cached parameters can come from application middleware as well as
  # Rails, so they may be cyclic, extremely deep, or much larger than Rack's
  # normal parser limits.
  module UploadedFiles
    MAX_NODES = 10_000
    MAX_DEPTH = 100
    MAX_FILES = 100
    MAX_NAME_BYTES = 256
    MAX_CONTENT_TYPE_BYTES = 256
    MAX_ERROR_BYTES = 256
    MAX_FILE_BYTES = (2**63) - 1
    STRING_BYTESIZE = String.instance_method(:bytesize)
    STRING_BYTESLICE = String.instance_method(:byteslice)

    module_function

    def extract(value, name = nil)
      files = []
      stack = [ [ value, name, 0 ] ]
      seen = {}
      nodes = 0

      while (entry = stack.pop)
        break if nodes >= MAX_NODES || files.size >= MAX_FILES

        current, field_name, depth = entry
        nodes += 1

        if action_dispatch_upload?(current)
          files << metadata(current.tempfile, field_name, current.content_type)
        elsif rack_upload?(current)
          files << metadata(rack_value(current, :tempfile), field_name || rack_value(current, :name),
                            rack_value(current, :type))
        elsif current.is_a?(Hash) || current.is_a?(Array)
          next if depth >= MAX_DEPTH || seen.key?(current.object_id)

          seen[current.object_id] = true
          push_children(stack, current, field_name, depth + 1, MAX_NODES - nodes - stack.size)
        end
      end

      files
    rescue StandardError, SystemStackError
      []
    end

    # The controller subscriber owns this Rack env key, but application
    # middleware can write it too. Treat it as an untrusted cache so malformed
    # metadata cannot bypass the same bounds applied by #extract.
    def normalize(value)
      return [] unless value.is_a?(Array)

      value.first(MAX_FILES).filter_map do |entry|
        next unless entry.is_a?(Hash)

        {
          name: safe_string(rack_value(entry, :name), MAX_NAME_BYTES),
          size: safe_emitted_size(rack_value(entry, :size)),
          content_type: safe_string(rack_value(entry, :content_type), MAX_CONTENT_TYPE_BYTES),
          error: safe_string(rack_value(entry, :error), MAX_ERROR_BYTES)
        }
      end
    rescue StandardError, SystemStackError
      []
    end

    def push_children(stack, value, name, depth, capacity)
      return if capacity <= 0

      children = []
      if value.is_a?(Hash)
        value.each do |key, child|
          children << [ child, safe_string(key, MAX_NAME_BYTES), depth ]
          break if children.size >= capacity
        end
      else
        value.each do |child|
          children << [ child, name, depth ]
          break if children.size >= capacity
        end
      end
      children.reverse_each { |child| stack << child }
    end

    def action_dispatch_upload?(value)
      defined?(ActionDispatch::Http::UploadedFile) && value.is_a?(ActionDispatch::Http::UploadedFile)
    end

    def rack_upload?(value)
      return false unless value.is_a?(Hash) && rack_key?(value, :filename) && rack_key?(value, :tempfile)

      tempfile = rack_value(value, :tempfile)
      tempfile.respond_to?(:read) && tempfile.respond_to?(:rewind) && tempfile.respond_to?(:size)
    end

    def rack_key?(hash, key)
      hash.key?(key) || hash.key?(key.to_s)
    end

    def rack_value(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    def metadata(tempfile, name, content_type)
      {
        name: safe_string(name, MAX_NAME_BYTES),
        size: safe_size(tempfile),
        content_type: safe_string(content_type, MAX_CONTENT_TYPE_BYTES),
        error: nil
      }
    end

    def safe_size(tempfile)
      size = tempfile.size
      return nil unless size.is_a?(Integer) && size >= 0

      [ size, MAX_FILE_BYTES ].min
    rescue StandardError, SystemStackError
      nil
    end

    def safe_emitted_size(size)
      return nil unless size.is_a?(Integer) && size >= 0

      [ size, MAX_FILE_BYTES ].min
    end

    def safe_string(value, max_bytes)
      return nil if value.nil?

      raw = value.is_a?(String) ? value : value.to_s
      source_limit = max_bytes + 4
      raw = STRING_BYTESLICE.bind_call(raw, 0, source_limit) if STRING_BYTESIZE.bind_call(raw) > source_limit
      text = String.new(raw).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      return text if text.bytesize <= max_bytes

      # byteslice can cut a multi-byte character; dropping only that partial
      # tail keeps the result valid UTF-8 and within the exact byte budget.
      text.byteslice(0, max_bytes).scrub("")
    end
  end
end
