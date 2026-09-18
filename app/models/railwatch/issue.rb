# frozen_string_literal: true

module Railwatch
  # A grouped exception or performance problem with a lifecycle. Lives in the
  # primary database so it keeps its sequential id after telemetry is pruned.
  class Issue < ApplicationRecord
    self.table_name = "railwatch_issues"
    class InvalidMerge < ArgumentError; end

    KINDS = %w[exception performance anomaly].freeze
    STATUSES = %w[open resolved ignored merged].freeze
    PRIORITIES = %w[low normal high urgent].freeze
    # How many recent occurrences a split by message looks at.
    SPLIT_SAMPLE = 200
    MERGE_CHAIN_LIMIT = 10

    def application = Application.current
    def environment = Environment.current
    # assignee is a plain id on an embedded install (User is not a table).
    def assignee
      assignee_id && User.find_by(id: assignee_id)
    end

    def assignee=(user)
      self.assignee_id = user&.id&.to_s
    end
    belongs_to :merged_into, class_name: "Issue", optional: true
    has_many :merged_issues, class_name: "Issue", foreign_key: :merged_into_id, inverse_of: :merged_into, dependent: :nullify
    has_many :comments, dependent: :destroy
    has_many :alerts, dependent: :nullify
    has_many :activities, class_name: "IssueActivity", dependent: :destroy

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }
    validates :priority, inclusion: { in: PRIORITIES }
    validates :group_hash, presence: true, uniqueness: { scope: :environment_id }
    validates :title, presence: true

    before_validation :assign_number, on: :create
    after_create :record_created_activity
    after_update :record_priority_activity
    after_update :record_assignee_activity

    scope :open, -> { where(status: "open") }
    scope :recent, -> { order(last_seen_at: :desc) }

    def key
      "#{application.issue_prefix}-#{number}"
    end

    def open? = status == "open"
    def resolved? = status == "resolved"
    def merged? = status == "merged"

    def resolve!(deploy: nil)
      record_status_change! { update!(status: "resolved", resolved_at: Time.current, resolved_in_deploy: deploy) }
    end

    def ignore!
      record_status_change! { update!(status: "ignored") }
    end

    def reopen!
      record_status_change! { update!(status: "open", resolved_at: nil, resolved_in_deploy: nil) }
    end

    # Merges this issue into `target`: moves comments over, folds occurrence
    # and affected-user counts into the target, widens its first/last seen
    # range, and marks this issue "merged". Future occurrences for this
    # issue's group_hash are then credited to the target (see
    # .record_occurrence!). Same environment only.
    def merge_into!(target)
      raise InvalidMerge, "both issues must be persisted before merging" unless persisted? && target&.persisted?

      transaction do
        # Every merge locks the same pair in the same order. Besides preventing
        # reciprocal requests from creating a cycle, lock! reloads both rows so
        # folding counts cannot overwrite a merge committed from a stale object.
        [ self, target ].sort_by(&:id).each(&:lock!)
        validate_merge_target!(target)

        comments.update_all(issue_id: target.id)
        target.update!(occurrences: target.occurrences + occurrences, affected_users: [ target.affected_users, affected_users ].max,
          first_seen_at: [ target.first_seen_at, first_seen_at ].min, last_seen_at: [ target.last_seen_at, last_seen_at ].max)
        update!(status: "merged", merged_into_id: target.id)
        activities.create!(kind: "merge", user: Viewer.user, data: { target_id: target.id, target_key: target.key })
        target.activities.create!(kind: "absorbed", user: Viewer.user, data: { source_id: id, source_key: key, occurrences: occurrences })
      end
    end

    # Gives the merged-in events back: occurrences counted on the target since
    # the merge stay there (they were credited under the target's own group),
    # only the count that came along at merge time moves back. Chained merges
    # must be unwound from the live end so an inner source cannot be restored
    # while its count is still included farther up the chain.
    def unmerge!
      transaction do
        target_id = self.class.where(id: id).pick(:merged_into_id)
        raise InvalidMerge, "cannot unmerge an issue that is not merged" unless target_id

        target = self.class.find(target_id)
        [ self, target ].sort_by(&:id).each(&:lock!)
        unless merged? && merged_into_id == target.id
          raise InvalidMerge, "issue merge changed; reload and try again"
        end
        if target.merged? || target.merged_into_id.present?
          raise InvalidMerge, "cannot unmerge this issue yet; unmerge #{target.key} first (top-down order)"
        end

        target.update!(occurrences: [ target.occurrences - occurrences, 0 ].max)
        update!(status: "open", merged_into_id: nil)
        activities.create!(kind: "unmerge", user: Viewer.user, data: { target_id: target.id, target_key: target.key })
      end
    end

    # Splits this issue by the raw message of its recent occurrences: one new
    # issue per distinct message, each taking that message's count, seen range
    # and sample, with this issue giving those occurrences up. Nothing moves in
    # the telemetry database -- the rows are still grouped under the hash the
    # gem sent -- so this separates what has already been seen; to split future
    # occurrences too, give the error a real fingerprint (Railwatch.fingerprint).
    # Returns the issues it created: [] when every recent occurrence carries
    # the same message, or when they have all been split off already.
    def split!(by: "message")
      return [] unless by == "message"

      rows = environment.with_telemetry { Telemetry::Exception.where(group_hash: group_hash).recent.limit(SPLIT_SAMPLE).to_a }
      groups = rows.group_by { |row| row.message.to_s }
      return [] if groups.size < 2

      transaction do
        pending = groups.reject { |message, _| environment.issues.exists?(group_hash: self.class.split_group_hash(group_hash, message)) }
        created = pending.map { |message, message_rows| split_off(message, message_rows) }
        next [] if created.empty?

        moved = created.sum(&:occurrences)
        update!(occurrences: [ occurrences - moved, 0 ].max)
        activities.create!(kind: "split", user: Viewer.user, data: { by: by, occurrences: moved, into: created.map(&:key) })
        created
      end
    end

    # Mirrors the gem's Record.group_hash (MD5, 32 hex chars) but joins on a
    # separator the gem never sends, so an issue split here can never collide
    # with one the gem itself would group.
    def self.split_group_hash(group_hash, message)
      Digest::MD5.hexdigest([ group_hash, message ].join("\x1f"))[0, 32]
    end

    # Called by the grouper for every new occurrence. Returns :new, :regressed,
    # or :seen so the caller can decide whether to alert.
    def self.record_occurrence!(environment:, group_hash:, kind:, title:, culprit:, occurred_at:, deploy:, user_ref:, sample:, source: nil)
      issue = find_or_initialize_by(environment_id: environment.id, group_hash: group_hash)
      return record_occurrence_on!(issue, environment:, kind:, title:, culprit:, occurred_at:, deploy:, sample:, source:) if issue.new_record?

      visited = {}
      0.upto(MERGE_CHAIN_LIMIT) do |depth|
        raise InvalidMerge, "cycle detected in issue merge chain" if visited[issue.id]
        visited[issue.id] = true

        next_id = nil
        result = nil
        # Lock only the row currently being inspected. If it has merged, release
        # that lock before following the pointer; this avoids taking chain locks
        # in an order that can deadlock with merge_into!.
        issue.with_lock do
          if issue.merged? || issue.merged_into_id.present?
            next_id = issue.merged_into_id
            raise InvalidMerge, "merged issue has no merge target" unless next_id
          else
            result = record_occurrence_on!(issue, environment:, kind:, title:, culprit:, occurred_at:, deploy:, sample:, source:)
          end
        end
        return result if result
        raise InvalidMerge, "issue merge chain exceeds #{MERGE_CHAIN_LIMIT} links" if depth == MERGE_CHAIN_LIMIT

        issue = find_by(id: next_id)
        raise InvalidMerge, "issue merge target no longer exists" unless issue
      end
    end

    # Routes an issue lifecycle event through every alert rule subscribed to it
    # whose filters match. Public so detectors (DetectAnomaliesJob) can route
    # their own events through the same path.
    def fire_alerts!(event, extra = {})
      return unless event
      application.alert_rules.where(event: event).find_each do |rule|
        payload = { issue_key: key, title: title, environment: environment.name, actor: Viewer.user&.name }.merge(extra)
        next unless rule.matches?(issue: self, payload: payload)
        rule.fire!(event: event, issue: self, payload: payload)
      end
    end

    # During the rollout the legacy one-workspace columns may already contain
    # a link. Materialize it once so old rows enter the per-workspace model
    # without losing synchronization.
    def linear_links_with_legacy = []

    private

    def self.record_occurrence_on!(issue, environment:, kind:, title:, culprit:, occurred_at:, deploy:, sample:, source:)
      outcome =
        if issue.new_record?
          issue.assign_attributes(application_id: environment.application.id, kind: kind, title: title, culprit: culprit,
                                  first_seen_at: occurred_at)
          :new
        elsif issue.resolved? && (issue.resolved_in_deploy.nil? || deploy.to_s != issue.resolved_in_deploy)
          issue.assign_attributes(status: "open", regressed_at: occurred_at, resolved_at: nil, resolved_in_deploy: nil)
          :regressed
        else
          :seen
        end
      issue.occurrences += 1
      issue.last_seen_at = occurred_at if issue.last_seen_at.nil? || occurred_at > issue.last_seen_at
      issue.sample = sample
      # Where the latest occurrence was raised: "browser" for a JavaScript
      # error the beacon reported, the Rails source for everything else.
      issue.source = source
      issue.title = title if outcome == :new
      issue.save!
      issue.activities.create!(kind: "regressed", data: { at: occurred_at }) if outcome == :regressed
      [ issue, outcome ]
    end
    private_class_method :record_occurrence_on!

    def validate_merge_target!(target)
      raise InvalidMerge, "can only merge issues in the same environment" unless target.environment_id == environment_id
      raise InvalidMerge, "cannot merge an issue into itself" if target.id == id
      raise InvalidMerge, "cannot merge an issue that is already merged" if merged? || merged_into_id.present?
      raise InvalidMerge, "merge target must be open" unless target.open?
      raise InvalidMerge, "merge target must not itself be merged" if target.merged_into_id.present?
    end

    def split_off(message, rows)
      latest = rows.max_by(&:occurred_at)
      issue = environment.issues.create!(application_id: application.id, kind: kind, culprit: culprit, source: source,
        group_hash: self.class.split_group_hash(group_hash, message),
        title: "#{latest.class_name}: #{message.first(200)}", occurrences: rows.size,
        first_seen_at: rows.min_by(&:occurred_at).occurred_at, last_seen_at: latest.occurred_at,
        sample: { exception_id: latest.id, handled: latest.handled, execution_id: latest.execution_id,
                  execution_preview: latest.execution_preview, deploy: latest.deploy,
                  fingerprint: latest.fingerprint, fingerprint_source: latest.fingerprint_source })
      issue.activities.create!(kind: "split", user: Viewer.user, data: { from_id: id, from_key: key, occurrences: rows.size })
      issue
    end

    def record_status_change!
      from = status
      yield
      return if status == from
      activities.create!(kind: "status", user: Viewer.user, data: { from: from, to: status })
      fire_alerts!({ "resolved" => "resolved_issue", "ignored" => "ignored_issue", "open" => "regressed_issue" }[status])
    end

    def record_created_activity
      activities.create!(kind: "created", user: Viewer.user)
    end

    def record_priority_activity
      return unless saved_change_to_priority?
      from, to = saved_change_to_priority
      activities.create!(kind: "priority", user: Viewer.user, data: { from: from, to: to })
    end

    def record_assignee_activity
      return unless saved_change_to_assignee_id?
      from, to = saved_change_to_assignee_id
      activities.create!(kind: "assignee", user: Viewer.user, data: { from_id: from, to_id: to })
      fire_alerts!("assigned_issue", assignee: assignee&.name, assignee_id: to) if to
    end


    def assign_number
      self.number ||= application.next_issue_number!
    end
  end
end
