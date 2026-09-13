# frozen_string_literal: true

module Railwatch
  # Sampling profiler for one execution, on top of whichever backend the app
  # has in its Gemfile: Vernier (preferred) or StackProf. Both are optional
  # dependencies, and every path here degrades to nil rather than raising --
  # a profile is a nice-to-have, never a reason to break a request.
  #
  # Both backends are process-global: there is one profiler per process, not
  # one per thread. An execution that starts while another one is being
  # profiled is simply not profiled, and is counted in `skipped`.
  module Profiler
    # What `stop` hands back. `interval` and `duration` are microseconds;
    # `collapsed` is the folded-stack text described on `collapse`.
    Profile = Struct.new(:profiler, :mode, :interval, :duration, :samples, :collapsed)

    # The profile currently running in this process: which backend started
    # it, when, and on which thread. Vernier samples every thread in the
    # process, and only the thread that asked for the profile is running
    # this execution.
    Handle = Struct.new(:backend, :mode, :interval, :started, :thread_id)

    # Preference order when config.profiler doesn't pin one.
    BACKENDS = %i[vernier stackprof].freeze

    # Uncompressed cap on the collapsed text. Rails stacks run 30-200 frames
    # deep, so a busy request folds to a few hundred KiB; gzip takes that
    # down ~30x, well inside a batch. Over the cap the least frequent stacks
    # are dropped: the long tail of one-sample stacks, not the profile's
    # shape.
    MAX_COLLAPSED_BYTES = 4 * 1024 * 1024

    # Frames with no Ruby file of their own (C functions). Vernier reports
    # those as "<cfunc>", StackProf as "<cfunc>" with a nil line.
    CFUNC = "<cfunc>"

    # Ruby's own stdlib directory, e.g. .../lib/ruby/3.4.0/.
    RUBY_LIB_PREFIX = "#{RbConfig::CONFIG['rubylibdir']}/"

    @lock = Mutex.new
    @running = nil
    @loadable = {}
    @skipped = 0

    class << self
      # Executions that wanted a profile while another one was already being
      # profiled in this process. Read by tests and diagnostics.
      attr_reader :skipped

      # Whether this process can profile at all. Memoised: the require is
      # the expensive part (see loadable?), choosing between two symbols is
      # not, so config.profiler stays live and overridable.
      def available?
        !backend.nil?
      end

      # :vernier, :stackprof, or nil when neither gem is installed.
      # config.profiler pins one by name (an unknown name simply doesn't
      # load, so profiling stays off); otherwise the first backend that
      # loads wins.
      def backend
        wanted = Railwatch.config.profiler
        return loadable?(wanted.to_sym) ? wanted.to_sym : nil if wanted

        BACKENDS.find { |name| loadable?(name) }
      end

      # Starts the process-global profiler and returns a handle, or nil when
      # no backend is installed, one is already running, or the backend
      # refused to start.
      def start(mode: :wall)
        return nil unless available?

        @lock.synchronize do
          if @running
            @skipped += 1
            next nil
          end

          handle = Handle.new(backend, mode, Railwatch.config.profile_interval_us,
                              Clock.monotonic, Thread.current.object_id)
          # StackProf returns false rather than raising when something else
          # in the process is already profiling.
          if start_backend(handle) == false
            @skipped += 1
            next nil
          end
          @running = handle
        end
      rescue StandardError => e
        Railwatch.debug { "profiler start failed: #{e.class}: #{e.message}" }
        nil
      end

      # Stops the running profile and folds it into a Profile, or nil when
      # nothing was running or anything at all went wrong on the way.
      def stop
        handle = @lock.synchronize { @running.tap { @running = nil } }
        return nil unless handle

        duration = Clock.micros_since(handle.started)
        result = stop_backend(handle)
        return nil unless result

        counts = sample_counts(result, handle.thread_id)
        Profile.new(handle.backend, handle.mode, handle.interval, duration,
                    counts.each_value.sum, format_counts(counts))
      rescue StandardError => e
        Railwatch.debug { "profiler stop failed: #{e.class}: #{e.message}" }
        nil
      end

      # Folded-stack text for a backend result: one `outermost;...;leaf
      # count` line per unique stack, most sampled first with ties broken by
      # the stack text, so the same profile always serialises to the same
      # bytes. Capped at MAX_COLLAPSED_BYTES.
      def collapse(result, thread_id: nil)
        format_counts(sample_counts(result, thread_id))
      end

      # Test hook: forgets which backends loaded, plus any state a killed
      # profile left behind.
      def reset!
        @lock.synchronize do
          @running = nil
          @loadable = {}
          @skipped = 0
        end
      end

      # Process._fork hook. A child inherits @running still holding the
      # Handle for a profile the parent was taking, and nothing in the child
      # ever stops it: `start` then sees a profile already running and every
      # execution in that worker is counted as skipped and never profiled
      # again. Clear the process-global state without taking @lock -- the
      # child is single-threaded here, and Ruby has already abandoned any
      # mutex a parent thread held across the fork.
      def restart_after_fork!
        @running = nil
        @loadable = {}
        @skipped = 0
        self
      end

      private

      # Whether a backend gem can be required, resolved once per process:
      # requiring is what has to be memoised, not the choice between two
      # symbols.
      def loadable?(name)
        return @loadable[name] if @loadable.key?(name)

        @loadable[name] = begin
          require name.to_s
          true
        rescue LoadError
          false
        end
      end

      def start_backend(handle)
        case handle.backend
        when :vernier then ::Vernier.start_profile(mode: handle.mode, interval: handle.interval)
        when :stackprof then ::StackProf.start(mode: handle.mode, interval: handle.interval, raw: true)
        end
      end

      def stop_backend(handle)
        case handle.backend
        when :vernier
          ::Vernier.stop_profile
        when :stackprof
          ::StackProf.stop
          ::StackProf.results
        end
      end

      # {collapsed stack => sample count}. StackProf hands back a Hash,
      # Vernier a Vernier::Result.
      def sample_counts(result, thread_id)
        result.is_a?(Hash) ? stackprof_counts(result) : vernier_counts(result, thread_id)
      end

      # Vernier samples every thread in the process -- an idle thread
      # sleeping through the whole window otherwise outweighs the work being
      # profiled -- so only the thread that started the profile is folded in.
      def vernier_counts(result, thread_id)
        counts = Hash.new(0)
        thread = result.threads[thread_id] || result.main_thread
        return counts unless thread

        table = result.stack_table
        labels = {}
        lines = {}
        weights = thread[:weights]
        thread[:samples].each_with_index do |stack_idx, i|
          counts[lines[stack_idx] ||= vernier_line(table, stack_idx, labels)] += weights[i]
        end
        counts
      end

      # Vernier's stack table is a tree of leaf -> parent links, so the walk
      # comes out leaf-first and is reversed into folded order.
      def vernier_line(table, stack_idx, labels)
        frames = []
        while stack_idx
          func_idx = table.frame_func_idx(table.stack_frame_idx(stack_idx))
          frames << (labels[func_idx] ||= label(table.func_name(func_idx), table.func_filename(func_idx),
                                                table.func_first_lineno(func_idx)))
          stack_idx = table.stack_parent_idx(stack_idx)
        end
        frames.reverse.join(";")
      end

      # StackProf's :raw is a flat array of `depth, frame_id * depth, weight`
      # groups with the outermost frame first -- decoded exactly as
      # StackProf::Report#print_stackcollapse decodes it.
      def stackprof_counts(result)
        counts = Hash.new(0)
        frames = result[:frames]
        raw = result[:raw]
        return counts unless frames && raw

        labels = {}
        i = 0
        while (depth = raw[i])
          line = raw[i + 1, depth].map { |id| labels[id] ||= stackprof_label(frames[id]) }.join(";")
          counts[line] += raw[i + depth + 1].to_i
          i += depth + 2
        end
        counts
      end

      def stackprof_label(frame)
        label(frame[:name], frame[:file], frame[:line])
      end

      # "Class#method (path:line)".
      def label(name, file, line)
        "#{name} (#{short_path(file)}:#{line.to_i})"
      end

      # App paths lose the Rails root, installed-gem paths become
      # "<gem>/relative/path" (version dropped: it repeats on every frame of
      # every line and the deploy already records it), Ruby's own lib
      # becomes "ruby/...". A frame with no file at all is a C function.
      def short_path(file)
        file = file.to_s
        return CFUNC if file.empty? || file == CFUNC
        return file.delete_prefix(Backtrace.app_root) if file.start_with?(Backtrace.app_root)
        return "ruby/#{file.delete_prefix(RUBY_LIB_PREFIX)}" if file.start_with?(RUBY_LIB_PREFIX)
        return file unless Backtrace.installed_gem_path?(file)

        dir = Gem.path.find { |path| file.start_with?("#{path}/") }
        rest = file.delete_prefix("#{dir}/").delete_prefix("gems/")
        rest.sub(/\A([^\/]+?)-\d[^\/]*\//, '\1/')
      end

      def format_counts(counts)
        text = +""
        counts.sort_by { |stack, count| [ -count, stack ] }.each do |stack, count|
          line = "#{stack} #{count}\n"
          break if text.bytesize + line.bytesize > MAX_COLLAPSED_BYTES
          text << line
        end
        text
      end
    end
  end
end
