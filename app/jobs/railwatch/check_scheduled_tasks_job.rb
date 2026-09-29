# frozen_string_literal: true

module Railwatch
  # Flags scheduled tasks that have not run when expected. Uses the schedule
  # string the gem sends (Solid Queue's cron / natural language) parsed with
  # fugit, which Solid Queue already depends on.
  class CheckScheduledTasksJob < ApplicationJob
    include DetectionSnapshotting

    queue_as :default

    GRACE = 5.minutes
    # A deploy restarts the worker, and Solid Queue skips (does not replay) the
    # recurring ticks that fell inside the restart window. A tick missed within
    # this long after a deploy is the deploy, not the scheduler.
    DEPLOY_GRACE = 15.minutes

    def perform(environment)
      require "fugit"
      tasks = environment.with_telemetry do
        last_runs = Telemetry::Execution.scheduled.where("occurred_at > ?", 30.days.ago).group(:task_key).maximum(:occurred_at)
        schedules = Telemetry::Execution.latest_schedules(last_runs.keys)
        last_runs.map { |key, last| [ key, last, schedules[key] ] }
      end
      last_deploy_at = environment.deploys.maximum(:deployed_at)
      configured = environment.with_telemetry { Telemetry::HealthSample.recurring_task_keys }
      open_missed = environment.issues.open.where("group_hash LIKE 'missed:%'").index_by(&:group_hash)
      tasks.each do |key, last_run, schedule|
        next if schedule.blank?
        # A task taken out of config/recurring.yml stops running on purpose.
        # Its history would otherwise read as a miss every window for 30 days
        # (reconcile_ingest_batches was live for four minutes and flagged 62
        # times). The gem ships the manifest of tasks Solid Queue is actually
        # running; a key absent from the newest one is removed, not missed.
        # It is not on every health sample -- it repeats only when it changes
        # or every five minutes, half the live window -- so read it with
        # HealthSample.recurring_task_keys, which skips the samples without
        # one. No manifest at all means an older gem: judge from history
        # alone, as before.
        if configured && !configured.include?(key)
          resolve_missed!(open_missed["missed:#{key}"], "Auto-resolved: #{key} is no longer a configured recurring task.")
          next
        end
        cron = Fugit.parse(schedule) or next
        expected = cron.next_time(last_run).to_t
        if expected > Time.current - GRACE
          # The task is back on schedule; a missed-run issue for it heals on its own.
          resolve_missed!(open_missed["missed:#{key}"], "Auto-resolved: #{key} ran again on schedule.")
          next
        end
        next if last_deploy_at && expected.between?(last_deploy_at - DEPLOY_GRACE, last_deploy_at + DEPLOY_GRACE)
        diagnosis = diagnose(key, expected)
        issue, outcome = Issue.record_occurrence!(
          environment: environment, group_hash: "missed:#{key}", kind: "performance",
          title: "Scheduled task #{key} missed its run (expected #{expected.utc.iso8601})#{diagnosis[:title_suffix]}",
          culprit: key, occurred_at: Time.current, deploy: nil, user_ref: nil,
          sample: { task_key: key, schedule: schedule, last_run: last_run.iso8601, expected: expected.iso8601 }.merge(diagnosis[:sample]))
        next unless outcome == :new || outcome == :regressed

        # Only on a new or regressed issue: the detectors re-run every few minutes
        # and capturing a snapshot on every breached window would query telemetry
        # for an issue nobody is newly looking at.
        latest = environment.with_telemetry { Telemetry::Execution.scheduled.where(task_key: key).recent.first }
        issue.update!(sample: issue.sample.merge("detection" => IssueDetectionSnapshot.capture(
          environment: environment, kind: "performance", telemetry_type: "scheduled_task",
          telemetry_group_hash: latest.group_hash, target: key, metric: "missed", from: expected, to: Time.current,
          representative_from: last_run,
          rule: { type: "schedule", task_key: key, schedule: schedule,
                 last_run: last_run.iso8601, expected: expected.iso8601 }
        )))
        payload = { issue_key: issue.key, title: issue.title, environment: environment.name }
        environment.application.alert_rules.where(event: "threshold").find_each do |rule|
          next unless rule.matches?(issue: issue, payload: payload)
          rule.fire!(event: "threshold", issue: issue, payload: payload)
        end
      end
    end

    private

    # Where the run went, from Solid Queue's own ledger when it is in this
    # process. A RecurringExecution row is written by the scheduler the moment
    # it enqueues a run, so its presence without a scheduled_task execution
    # means "enqueued, never performed" (no worker, or a wedged one); its
    # absence means the scheduler itself never fired. The hosted platform, and
    # any adapter other than Solid Queue, only ever sees the absence of the
    # run and reports it as before.
    def diagnose(key, expected)
      return NO_DIAGNOSIS unless defined?(::SolidQueue::RecurringExecution)

      enqueued_at = Railwatch.ignore { ::SolidQueue::RecurringExecution.where(task_key: key).where("run_at >= ?", expected - 1.minute).maximum(:run_at) }
      workers = Railwatch.ignore { ::SolidQueue::Process.where(kind: "Worker").count }
      if enqueued_at
        { title_suffix: workers.zero? ? ": enqueued, but no Solid Queue worker is running" : ": enqueued, not yet performed",
          sample: { enqueued_at: enqueued_at.iso8601, workers: workers, cause: workers.zero? ? "no_worker" : "backlog" } }
      else
        { title_suffix: ": the scheduler never enqueued it",
          sample: { enqueued_at: nil, workers: workers, cause: "scheduler" } }
      end
    rescue StandardError
      NO_DIAGNOSIS
    end

    NO_DIAGNOSIS = { title_suffix: "", sample: {} }.freeze

    # Sentry Crons marked a monitor OK again on the next successful check-in;
    # the same here: once the task has run inside its window again, the open
    # missed-run issue resolves with an activity row, so it does not sit open
    # until someone notices it is stale.
    def resolve_missed!(issue, body)
      return unless issue
      issue.resolve!
      issue.activities.create!(kind: "comment", data: { body: body })
    end
  end
end
