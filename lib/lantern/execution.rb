# frozen_string_literal: true

require "securerandom"

module Lantern
  # The parent of every child record: one HTTP request, one job attempt, one
  # scheduled task run, or one command. Holds the sampling decision, the trace
  # id, the current lifecycle stage, and the counters that end up on the parent
  # record. Never touches the database.
  class Execution
    SOURCES = %i[request job scheduled_task command].freeze
    MAX_RECORDS = 10_000
    COUNTERS = %i[queries cached_queries exceptions logs cache_events jobs_enqueued mail
                  broadcasts notifications outgoing_requests storage_ops view_renders
                  transactions hydrated_models lazy_loads deprecations].freeze

    attr_reader :source, :id, :trace_id, :parent_id, :started_at, :started_mono, :counters,
                :stages, :stage_durations, :query_groups, :records, :dropped_records
    attr_accessor :sampled, :exception_preview, :paused_depth,
                  :peak_memory, :allocations_start, :gc_time_start
    attr_reader :preview, :user_id, :tenant

    def preview=(value)
      @preview = value
      @envelope = nil
    end

    def user_id=(value)
      @user_id = value
      @envelope = nil
    end

    def tenant=(value)
      @tenant = value
      @envelope = nil
    end

    def initialize(source:, sampled:, trace_id: nil, parent_id: nil, preview: nil)
      raise ArgumentError, "unknown source #{source}" unless SOURCES.include?(source)

      @source = source
      @id = SecureRandom.uuid
      @trace_id = trace_id || SecureRandom.uuid
      @parent_id = parent_id
      @sampled = sampled
      @preview = preview
      @started_at = Clock.now
      @started_mono = Clock.monotonic
      @counters = COUNTERS.to_h { |c| [ c, 0 ] }
      @stages = []
      @stage_durations = {}
      @current_stage = nil
      @current_stage_started = @started_mono
      @query_groups = Hash.new(0)
      @paused_depth = 0
      @exception_preview = nil
      @user_id = nil
      @tenant = nil
      @records = []
      @dropped_records = 0
      @allocations_start = GC.stat(:total_allocated_objects)
      @gc_time_start = GC.stat(:time) if GC.stat.key?(:time)
    end

    def sampled?
      @sampled
    end

    def paused?
      @paused_depth.positive?
    end

    def recording?
      sampled? && !paused?
    end

    def stage
      @current_stage
    end

    # Close the current stage and open the next. Stage durations are integers
    # in microseconds keyed by stage name, like Nightwatch's request record.
    def enter_stage(name)
      now = Clock.monotonic
      if @current_stage
        @stage_durations[@current_stage] = (@stage_durations[@current_stage] || 0) + ((now - @current_stage_started) * 1_000_000).round
      end
      @current_stage = name
      @current_stage_started = now
      @stages << name
      @envelope = nil
    end

    def finish_stages
      enter_stage(nil)
      @current_stage = nil
    end

    # Child records wait here until the execution ends, so a sampling
    # decision made late (route-level lantern_sample, dont_sample) still
    # applies to everything recorded before it.
    def buffer(record)
      if @records.size >= MAX_RECORDS
        @dropped_records += 1
      else
        @records << record
      end
    end

    # Resident set size in bytes, Linux only. Read once at execution end.
    def capture_memory
      @peak_memory = File.read("/proc/self/statm").split[1].to_i * 4096
    rescue StandardError
      nil
    end

    def count(counter, by = 1)
      @counters[counter] += by
    end

    def track_query_group(group)
      @query_groups[group] += 1
    end

    def duration
      Clock.micros_since(@started_mono)
    end

    def allocations
      GC.stat(:total_allocated_objects) - @allocations_start
    end

    def gc_time
      return nil unless @gc_time_start
      GC.stat(:time) - @gc_time_start
    end

    # The envelope every child record shares with its parent. Rebuilt only
    # when a stage, user, tenant, or preview changes; records merge a copy.
    def envelope
      @envelope ||= {
        trace_id: @trace_id,
        execution_source: @source.name,
        execution_id: @id,
        execution_preview: @preview,
        execution_stage: @current_stage&.name,
        user: @user_id,
        tenant: @tenant
      }.freeze
    end
  end
end
