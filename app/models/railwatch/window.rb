# frozen_string_literal: true

module Railwatch
  # The time range a telemetry page, API call, or MCP tool looks at: one of the
  # fixed presets ("1h" .. "30d") ending now, or a custom [from, to] pair. The
  # dashboard, the JSON API, and MCP all resolve their ?window= / "window"
  # argument through here so the presets and the default agree everywhere.
  class Window
    PRESETS = { "1h" => 1.hour, "6h" => 6.hours, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    DEFAULT = "24h"
    MAX_CUSTOM_RANGE = 90.days

    attr_reader :key, :from, :to

    # A preset key, or anything else for the default.
    def self.preset(key)
      key = PRESETS.key?(key.to_s) ? key.to_s : DEFAULT
      to = Time.current
      new(key, to - PRESETS[key], to)
    end

    # A custom range from ?from=&to= when both parse, are in order, and span
    # no more than MAX_CUSTOM_RANGE; otherwise the preset (or default).
    def self.parse(window: nil, from: nil, to: nil)
      custom(from, to) || preset(window)
    end

    def self.custom(from, to)
      from = parse_time(from) or return
      to = to.blank? ? Time.current : parse_time(to) or return
      new("custom", from, to) if to > from && (to - from) <= MAX_CUSTOM_RANGE
    end

    def self.parse_time(value)
      return if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :parse_time

    def initialize(key, from, to)
      @key = key
      @from = from
      @to = to
    end

    def custom? = key == "custom"
    def range = [ from, to ]
    def span = to - from

    # The same length immediately before this one, for "vs. previous period".
    def previous
      self.class.new(key, from - span, from)
    end

    def to_h
      { from: from.iso8601(6), to: to.iso8601(6) }
    end

    # Query params that reproduce this window on another page.
    def to_params
      custom? ? to_h : { window: key }
    end
  end
end
