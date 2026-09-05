# frozen_string_literal: true

module Lantern
  # Turns already-cached request parameters into a bounded, JSON-safe tree.
  # Request caches are normally Rails hashes of strings, but Rack middleware
  # can populate them with arbitrary, cyclic, or extremely large objects.
  module RequestPayload
    MAX_BYTES = 65_536
    MAX_NODES = 10_000
    MAX_DEPTH = 50
    MAX_KEY_BYTES = 256
    MAX_STRING_BYTES = 4_096
    STRING_BYTESIZE = String.instance_method(:bytesize)
    STRING_BYTESLICE = String.instance_method(:byteslice)
    OMIT = Object.new.freeze
    Result = Data.define(:value, :truncated, :failed)

    module_function

    def normalize(value)
      state = { nodes: 0, seen: {}, truncated: false, failed: false }
      normalized, = build(value, MAX_BYTES, 0, state)
      unless normalized.is_a?(Hash)
        state[:truncated] = true
        state[:failed] = true
        normalized = nil
      end
      Result.new(value: normalized, truncated: state[:truncated], failed: state[:failed])
    rescue StandardError, SystemStackError
      Result.new(value: nil, truncated: true, failed: true)
    end

    def build(value, budget, depth, state)
      return omitted(state) if state[:nodes] >= MAX_NODES || budget < 2

      state[:nodes] += 1
      case value
      when Hash
        build_hash(value, budget, depth, state)
      when Array
        build_array(value, budget, depth, state)
      else
        build_scalar(value, budget, state)
      end
    end

    def build_hash(value, budget, depth, state)
      return omitted(state) if depth >= MAX_DEPTH
      return cyclic(state) if state[:seen].key?(value.object_id)

      state[:seen][value.object_id] = true
      seen = true
      out = {}
      used = 2 # {}
      value.each do |raw_key, raw_value|
        break truncated(state) if state[:nodes] >= MAX_NODES
        state[:nodes] += 1 # Count the key separately from its value.

        key, key_safe = safe_key(raw_key, state)
        if out.key?(key)
          truncated(state)
          next
        end

        prefix = out.empty? ? 0 : 1
        overhead = prefix + JSON.generate(key).bytesize + 1 # comma + key + colon
        if used + overhead + 2 > budget
          truncated(state)
          break
        end

        child, child_bytes =
          if key_safe
            build(raw_value, budget - used - overhead, depth + 1, state)
          else
            filtered = Redactor::FILTERED
            [ filtered, JSON.generate(filtered).bytesize ]
          end
        if child_bytes > budget - used - overhead
          truncated(state)
          break
        end
        next if child.equal?(OMIT)

        out[key] = child
        used += overhead + child_bytes
      end
      [ out, used ]
    ensure
      state[:seen].delete(value.object_id) if seen
    end

    def build_array(value, budget, depth, state)
      return omitted(state) if depth >= MAX_DEPTH
      return cyclic(state) if state[:seen].key?(value.object_id)

      state[:seen][value.object_id] = true
      seen = true
      out = []
      used = 2 # []
      value.each do |raw_value|
        break truncated(state) if state[:nodes] >= MAX_NODES

        prefix = out.empty? ? 0 : 1
        if used + prefix + 2 > budget
          truncated(state)
          break
        end

        child, child_bytes = build(raw_value, budget - used - prefix, depth + 1, state)
        next if child.equal?(OMIT)

        out << child
        used += prefix + child_bytes
      end
      [ out, used ]
    ensure
      state[:seen].delete(value.object_id) if seen
    end

    def build_scalar(value, budget, state)
      scalar = json_scalar(value, state)
      encoded = JSON.generate(scalar)
      return [ scalar, encoded.bytesize ] if encoded.bytesize <= budget

      return omitted(state) unless scalar.is_a?(String)

      truncated(state)
      fit_string(scalar, budget)
    rescue StandardError, SystemStackError
      omitted(state)
    end

    def json_scalar(value, state)
      case value
      when String
        safe_string(value, MAX_STRING_BYTES, state)
      when Symbol
        safe_string(value.name, MAX_STRING_BYTES, state)
      when Integer
        if value.bit_length <= 63
          value
        else
          truncated(state)
          "[INTEGER TOO LARGE]"
        end
      when Float
        if value.finite?
          value
        else
          truncated(state)
          nil
        end
      when true, false, nil
        value
      else
        truncated(state)
        safe_string("[#{value.class.name || "Object"}]", MAX_STRING_BYTES, state)
      end
    end

    def safe_key(value, state)
      safe = true
      raw =
        case value
        when String then value
        when Symbol then value.name
        when Integer
          if value.bit_length <= 63
            value.to_s
          else
            truncated(state)
            safe = false
            "[INTEGER TOO LARGE]"
          end
        else
          truncated(state)
          safe = false
          "[#{value.class.name || "Object"}]"
        end
      strict = String.new(raw).encode(Encoding::UTF_8)
      if strict.bytesize > MAX_KEY_BYTES
        truncated(state)
        safe = false
      end
      [ safe_string(raw, MAX_KEY_BYTES, state), safe ]
    rescue StandardError, SystemStackError
      truncated(state)
      [ "[INVALID KEY]", false ]
    end

    def safe_string(value, max_bytes, state)
      # String.new drops singleton overrides carried by a hostile String
      # subclass before calling encoding methods on it. Slice before copying
      # or transcoding so a huge cached string cannot create another huge
      # allocation merely to emit its first few KiB.
      source_limit = max_bytes + 4
      source =
        if STRING_BYTESIZE.bind_call(value) > source_limit
          truncated(state)
          STRING_BYTESLICE.bind_call(value, 0, source_limit)
        else
          value
        end
      source = String.new(source)
      text = begin
        source.encode(Encoding::UTF_8)
      rescue EncodingError
        truncated(state)
        source.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      end
      return text if text.bytesize <= max_bytes

      truncated(state)
      text.byteslice(0, max_bytes).scrub("")
    rescue StandardError, SystemStackError
      truncated(state)
      "[INVALID STRING]"
    end

    def fit_string(value, budget)
      return [ OMIT, 0 ] if budget < 2

      low = 0
      high = value.bytesize
      best = ""
      best_bytes = 2
      while low <= high
        midpoint = (low + high) / 2
        candidate = value.byteslice(0, midpoint).scrub("")
        bytes = JSON.generate(candidate).bytesize
        if bytes <= budget
          best = candidate
          best_bytes = bytes
          low = midpoint + 1
        else
          high = midpoint - 1
        end
      end
      [ best, best_bytes ]
    end

    def cyclic(state)
      state[:truncated] = true
      state[:failed] = true
      [ OMIT, 0 ]
    end

    def omitted(state)
      truncated(state)
      [ OMIT, 0 ]
    end

    def truncated(state)
      state[:truncated] = true
      nil
    end
  end
end
