# frozen_string_literal: true

module Railwatch
  # A bounded, read-only view of the evidence Railwatch has about its own
  # pipeline. Cloud uses the same reader, with capabilities selected explicitly
  # so a tenant can never inherit the hosting process's writer/export settings.
  class MonitoringHealth
    FRESHNESS_WINDOW = 10.minutes
    CAPTURE_WINDOW = 1.hour
    BATCH_LIMIT = 1_000
    BACKLOG_LIMIT = 200
    FOLLOWUP_WARNING_AGE = 5.minutes
    PRUNE_ALLOWANCE = 1.day
    # These tables have a leading time index. Other raw tables are deliberately
    # not scanned: this is evidence of a backlog, not a claim to count every row.
    RETENTION_PROBES = {
      "queries" => [ Telemetry::Query, :occurred_at ],
      "exceptions" => [ Telemetry::Exception, :occurred_at ],
      "logs" => [ Telemetry::Log, :occurred_at ],
      "sessions" => [ Telemetry::Session, :occurred_at ],
      "health_samples" => [ Telemetry::HealthSample, :sampled_at ],
      "ingest_batches" => [ Telemetry::IngestBatch, :received_at ]
    }.freeze
    TELEMETRY_CHECKS = %i[freshness capture storage retention followups export].freeze

    def initialize(environment, host: :embedded, now: Time.current, config: Railwatch.config)
      raise ArgumentError, "unknown monitoring health host" unless %i[embedded cloud].include?(host)

      @environment, @host, @now, @config = environment, host, now, config
    end

    def to_h
      @snapshot ||= begin
        checks = telemetry_checks
        checks[:maintenance] = safely { maintenance }
        checks[:writer] = safely { writer }
        attention = attention_for(checks)
        statuses = checks.values.map { |check| check[:status] }
        status = if attention.any? { |item| item[:severity] == "critical" }
          "critical"
        elsif attention.any?
          "warning"
        elsif statuses.include?("unknown")
          "unknown"
        else
          "ok"
        end
        { checked_at: @now, host: @host.to_s, status: status, attention: attention }.merge(checks)
      end
    end

    def summary = to_h.slice(:status, :checked_at, :attention)

    private

    def embedded? = @host == :embedded

    def telemetry_checks
      # Environment#with_telemetry on Cloud creates a missing database. A
      # diagnostics GET must not create, migrate or repair anything.
      return unavailable_checks unless @environment.telemetry_exists?

      TelemetryRecord.with_tenant(@environment.slug) do
        TELEMETRY_CHECKS.to_h { |name| [ name, safely { send(name) } ] }
      end
    rescue ActiveRecord::ActiveRecordError, Railwatch::DatabaseNotConfigured, IOError, SystemCallError
      unavailable_checks
    end

    def unavailable_checks
      checks = TELEMETRY_CHECKS.to_h { |name| [ name, unknown("Telemetry storage is unavailable; this check could not be read.") ] }
      checks[:export] = export if !embedded? || !@config.export_enabled || !@config.export?
      checks
    end

    def safely
      yield
    rescue ActiveRecord::ActiveRecordError, Railwatch::DatabaseNotConfigured, IOError, SystemCallError
      # Adapter errors can contain SQL, paths and credentials. None are props.
      unknown("This check could not be read. Verify the Railwatch database and migrations.")
    end

    def freshness
      ingest = freshness_for(Telemetry::IngestBatch.recent.pick(:received_at), "ingest batch")
      health = freshness_for(Telemetry::HealthSample.recent.pick(:sampled_at), "process health sample")
      paused = @environment.paused?
      if paused
        ingest = ingest.merge(status: "not_applicable", message: "Ingest is paused for this environment.")
        health = health.merge(status: "not_applicable", message: "Ingest is paused for this environment.")
      end
      { status: worst(ingest[:status], health[:status]), ingest: ingest, health: health, paused: paused,
        message: "Freshness uses the newest recorded batch and process sample. Quiet traffic alone does not prove a failure." }
    end

    def freshness_for(at, label)
      return unknown("No #{label} has been recorded.").merge(at: nil, age_seconds: nil) unless at
      age = (@now - at).round
      return unknown("The newest #{label} is in the future; check the reporting clock.").merge(at: at, age_seconds: nil) if age < -300

      stale = age > FRESHNESS_WINDOW
      { status: stale ? "warning" : "ok", at: at, age_seconds: [ age, 0 ].max,
        message: stale ? "No #{label} in the last ten minutes." : "#{label.capitalize} recorded within ten minutes." }
    end

    def capture
      rows = Telemetry::IngestBatch.where(received_at: (@now - CAPTURE_WINDOW)..@now).recent.limit(BATCH_LIMIT + 1)
        .pluck(:received_at, :accepted, :rejected, :dropped_by_client, :backpressure_factor)
      limited = rows.length > BATCH_LIMIT
      rows = rows.first(BATCH_LIMIT)
      accepted, rejected, dropped = (1..3).map { |column| rows.sum { |row| row[column].to_i } }
      factor = rows.map { |row| row[4].to_f }.max
      status = if rows.empty? then "unknown"
      elsif rejected.positive? || dropped.positive? || factor.to_f > 1 then "warning"
      else "ok"
      end
      { status: status, from: @now - CAPTURE_WINDOW, to: @now, covered_from: rows.last&.first,
        batches: rows.length, limit: BATCH_LIMIT, limited: limited,
        accepted: rows.empty? ? nil : accepted, rejected: rows.empty? ? nil : rejected,
        dropped_by_client: rows.empty? ? nil : dropped, max_backpressure_factor: factor,
        message: "Recorded batches only: loss in undelivered batches and executions skipped by sampling are unknown. " \
                 "A backpressure factor above 1 reduces capture below the configured sample rate." }
    end

    def storage
      SqliteStorage.new(TelemetryRecord.connection, budget_bytes: embedded? ? @config.telemetry_storage_budget_bytes : nil).to_h
    end

    def retention
      days = @environment.retention_days
      cutoff = @now - days.days
      probes = RETENTION_PROBES.map do |table, (model, column)|
        safely do
          # An old/incomplete schema may be missing the index. Even LIMIT 1
          # would scan and sort without it, so decline the check explicitly.
          indexed = model.connection.indexes(table).any? { |index| index.columns.first == column.to_s && !index.where }
          next unknown("The time index is unavailable; no scan was performed.").merge(table: table) unless indexed

          oldest = model.order(column).limit(1).pick(column)
          # Session pruning keeps the partial hour at the retention boundary.
          table_cutoff = table == "sessions" ? cutoff.utc.beginning_of_hour : cutoff
          expired = oldest && oldest < table_cutoff
          behind = oldest && oldest < table_cutoff - PRUNE_ALLOWANCE
          { table: table, status: behind ? "warning" : "ok", oldest_at: oldest, expired: !!expired, behind: !!behind }
        end.merge(table: table)
      end
      { status: worst(*probes.map { |probe| probe[:status] }), days: days, cutoff: cutoff, probes: probes,
        message: "Oldest rows in six indexed tables are checked; other tables and total expired row counts are unknown. " \
                 "Expired rows may remain until the next daily prune. A backlog needs attention when it is more than one day past the cutoff." }
    end

    def followups
      model, column = embedded? ? [ Telemetry::IngestBatch, :received_at ] : [ Telemetry::IngestReceipt, :committed_at ]
      rows = model.with_pending_followups.reorder(column).limit(BACKLOG_LIMIT + 1).pluck(column)
      oldest = rows.first
      age = oldest && [ (@now - oldest).round, 0 ].max
      { status: age && age > FOLLOWUP_WARNING_AGE ? "warning" : "ok", oldest_at: oldest, age_seconds: age,
        pending: [ rows.length, BACKLOG_LIMIT ].min, limited: rows.length > BACKLOG_LIMIT, limit: BACKLOG_LIMIT,
        message: embedded? ? "Committed batches waiting for issue grouping; embedded maintenance drains this ledger." :
          "Committed deliveries waiting for Cloud follow-ups; the Cloud job queue drains these receipts." }
    end

    def maintenance
      return not_applicable("Cloud schedules maintenance through its job queue. Embedded task leases are not available for this environment.") unless embedded?

      tasks = MaintenanceTask.where(name: Maintenance::TASKS.keys).select(:name, :last_run_at, :lease_expires_at).index_by(&:name)
      rows = Maintenance::TASKS.map do |name, (every, lease, _body)|
        task = tasks[name]
        if name == "export_expiry" && !@config.export?
          next { name: name, status: "not_applicable", state: "Export disabled" }
        end
        last = task&.last_run_at
        expires = task&.lease_expires_at
        running = expires && expires > @now
        overdue = !running && ((last && last + every + lease < @now) || (expires && expires < @now))
        { name: name, last_run_at: last, next_due_at: last && last + every, lease_expires_at: expires,
          status: overdue ? "warning" : (running || last ? "ok" : "unknown"),
          state: running ? "Lease active" : (overdue ? "Overdue" : (last ? "Scheduled" : "Never recorded")) }
      end
      { status: worst(*rows.map { |row| row[:status] }), tasks: rows,
        message: "Last run means successful completion. Active leases do not prove progress; failure details are not persisted." }
    end

    def writer
      return not_applicable("Cloud ingestion runs on the service. This environment has no embedded writer to inspect.") unless embedded?

      if Writer.running?
        { status: "ok", mode: "writer_process", message: "This process is the embedded writer." }
      elsif Writer.expected?
        { status: "unknown", mode: "shared_writer", message: "A shared writer is expected. Listener reachability is not probed; batch freshness shows the latest committed work." }
      else
        { status: "unknown", mode: "local_transport", message: "Local transport can use a shared writer or its in-process fallback. The active path is not persisted; batch freshness shows the latest committed work." }
      end
    end

    def export
      return not_applicable("Cloud receives telemetry; this environment does not run the embedded export outbox.") unless embedded?
      return not_applicable("Telemetry export is disabled for this embedded install.").merge(enabled: false) unless @config.export_enabled
      return { status: "warning", enabled: true, message: "Export is configured but unavailable. Run bin/rails railwatch:doctor to check export configuration." } unless @config.export?

      # Match only the configured binding. Never select its URL, credential
      # digest, producer id, lease token, payload or error text for the page.
      destination = Telemetry::ExportDestination.where(url_sha256: Telemetry::ExportDestination.digest(@config.resolved_export_url))
        .select(:id, :state, :retry_at, :queued_bytes, :queued_deliveries, :counters).first
      return unknown("Export is enabled; no destination has been recorded yet.").merge(enabled: true) unless destination

      deliveries = Telemetry::ExportDelivery.where(export_destination_id: destination.id)
      oldest = deliveries.live.order(:id).limit(1).pick(:enqueued_at)
      # Last enqueued delivery is a single indexed lookup. It is not falsely
      # described as the latest successful delivery, which could require a scan.
      latest = deliveries.order(id: :desc).limit(1).pick(:enqueued_at, :state, :disposition)
      blocked = %w[unauthorized inactive].include?(destination.state)
      old = oldest && @now - oldest > FOLLOWUP_WARNING_AGE
      full = destination.queued_bytes >= @config.export_max_bytes || destination.queued_deliveries >= @config.export_max_deliveries
      { status: blocked ? "critical" : (old || full || destination.state == "deferred" ? "warning" : "ok"),
        enabled: true, destination_state: destination.state, queued_bytes: destination.queued_bytes,
        queued_deliveries: destination.queued_deliveries, oldest_at: oldest, retry_at: destination.retry_at,
        latest_enqueued_at: latest&.[](0), latest_state: latest&.[](1), latest_disposition: latest&.[](2),
        counters: Telemetry::ExportDestination::COUNTERS.to_h { |name| [ name, destination.counters.fetch(name, 0).to_i ] },
        limits: { bytes: @config.export_max_bytes, deliveries: @config.export_max_deliveries, age_seconds: @config.export_max_age },
        message: "Queue totals and lifetime counters come from the configured destination. Shed counts records; other counters count deliveries. Export loss does not imply local telemetry was deleted." }
    end

    def attention_for(checks)
      titles = { freshness: "Telemetry is stale", capture: "Capture loss or backpressure recorded", storage: "Telemetry storage needs attention",
                 retention: "Retention pruning is behind", followups: "Ingest follow-ups are delayed", maintenance: "Maintenance is overdue",
                 export: "Telemetry export needs attention" }
      titles.filter_map do |key, title|
        check = checks[key]
        next unless %w[warning critical].include?(check[:status])

        detail = case key
        when :capture then "#{check[:dropped_by_client]} reported client drops, #{check[:rejected]} rejected records; peak backpressure #{check[:max_backpressure_factor]}× in the inspected batches."
        when :freshness then [ check[:ingest], check[:health] ].select { |item| item[:status] == "warning" }.map { |item| item[:message] }.join(" ")
        when :storage then check.dig(:budget, :message) || check[:message]
        when :retention then "Rows more than a day past retention remain in #{check[:probes].select { |probe| probe[:behind] }.map { |probe| probe[:table] }.join(', ')}. Check the prune schedule and available disk space."
        when :followups then "#{check[:limited] ? 'At least ' : ''}#{check[:pending]} committed #{embedded? ? 'batches' : 'deliveries'} still need follow-ups; the oldest has waited more than five minutes."
        when :maintenance then "Overdue tasks: #{check[:tasks].select { |task| task[:status] == 'warning' }.map { |task| task[:name] }.join(', ')}. Check the embedded maintenance process."
        when :export then check[:destination_state] ? "Export destination is #{check[:destination_state]}; #{check[:queued_deliveries]} deliveries are queued. Check the destination and sender with bin/rails railwatch:export:status." : check[:message]
        else check[:message]
        end
        { key: key.to_s, severity: check[:status], title: title, detail: detail }
      end
    end

    def unknown(message) = { status: "unknown", message: message }
    def not_applicable(message) = { status: "not_applicable", message: message }

    def worst(*statuses)
      %w[critical warning unknown ok not_applicable].find { |status| statuses.include?(status) } || "unknown"
    end
  end
end
