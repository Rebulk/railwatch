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
    ARRAY_FIRST = Array.instance_method(:first)
    ARRAY_EACH = Array.instance_method(:each)
    HASH_EACH = Hash.instance_method(:each)
    HASH_KEY = Hash.instance_method(:key?)
    HASH_AREF = Hash.instance_method(:[])
    OBJECT_ID = Object.instance_method(:object_id)
    SINGLETON_CLASS = Object.instance_method(:singleton_class)
    PUBLIC_METHOD_DEFINED = Module.instance_method(:public_method_defined?)

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
        elsif Hash === current || Array === current
          identity = OBJECT_ID.bind_call(current)
          next if depth >= MAX_DEPTH || seen.key?(identity)

          seen[identity] = true
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
      return [] unless Array === value

      ARRAY_FIRST.bind_call(value, MAX_FILES).filter_map do |entry|
        next unless Hash === entry

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
      if Hash === value
        HASH_EACH.bind_call(value) do |key, child|
          children << [ child, safe_string(key, MAX_NAME_BYTES), depth ]
          break if children.size >= capacity
        end
      else
        ARRAY_EACH.bind_call(value) do |child|
          children << [ child, name, depth ]
          break if children.size >= capacity
        end
      end
      children.reverse_each { |child| stack << child }
    end

    def action_dispatch_upload?(value)
      defined?(ActionDispatch::Http::UploadedFile) && ActionDispatch::Http::UploadedFile === value
    end

    def rack_upload?(value)
      return false unless Hash === value && rack_key?(value, :filename) && rack_key?(value, :tempfile)

      tempfile = rack_value(value, :tempfile)
      methods = SINGLETON_CLASS.bind_call(tempfile)
      PUBLIC_METHOD_DEFINED.bind_call(methods, :read) && PUBLIC_METHOD_DEFINED.bind_call(methods, :rewind) &&
        PUBLIC_METHOD_DEFINED.bind_call(methods, :size)
    rescue TypeError
      false
    end

    def rack_key?(hash, key)
      HASH_KEY.bind_call(hash, key) || HASH_KEY.bind_call(hash, key.to_s)
    end

    def rack_value(hash, key)
      HASH_KEY.bind_call(hash, key) ? HASH_AREF.bind_call(hash, key) : HASH_AREF.bind_call(hash, key.to_s)
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
      return nil unless Integer === size && size >= 0

      [ size, MAX_FILE_BYTES ].min
    rescue StandardError, SystemStackError
      nil
    end

    def safe_emitted_size(size)
      return nil unless Integer === size && size >= 0

      [ size, MAX_FILE_BYTES ].min
    end

    def safe_string(value, max_bytes)
      raw =
        case value
        when nil then return nil
        when String then value
        when Symbol then value.name
        when Integer
          value.to_s if value.bit_length <= 63
        when Float
          value.to_s if value.finite?
        when true, false
          value.to_s
        end
      return nil unless raw

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
