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

    def push_children(stack, value, name, depth, capacity)
      return if capacity <= 0

      children = []
      if value.is_a?(Hash)
        value.each do |key, child|
          children << [ child, key.to_s, depth ]
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
      value.is_a?(Hash) && rack_key?(value, :filename) && rack_key?(value, :tempfile) &&
        rack_value(value, :tempfile).respond_to?(:size)
    end

    def rack_key?(hash, key)
      hash.key?(key) || hash.key?(key.to_s)
    end

    def rack_value(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    def metadata(tempfile, name, content_type)
      { name: name&.to_s, size: (tempfile.size rescue nil), content_type: content_type, error: nil }
    end
  end
end
