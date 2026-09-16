# frozen_string_literal: true

module Railwatch
  class Alert < ApplicationRecord
    MAX_DELIVERY_ATTEMPTS = 5
    DELIVERY_LEASE = 5.minutes
    ENQUEUE_LEASE = 5.minutes
    RETRY_DELAYS = [ 1.minute, 5.minutes, 15.minutes, 1.hour ].freeze

    # An alert is always addressed to an integration; the rule is only why it
    # fired, and a "Send test" delivery has no rule behind it at all.
    # No integrations in an embedded install yet: alerts are recorded, not delivered.
    def integration = nil

    def integration=(_)
      nil
    end
    belongs_to :alert_rule, optional: true
    belongs_to :issue, optional: true
    belongs_to :summary_alert, class_name: "Alert", optional: true
    has_many :summarized_alerts, class_name: "Alert", foreign_key: :summary_alert_id,
      dependent: :nullify, inverse_of: :summary_alert

    # `delivering` is a leased claim. A process that disappears while holding
    # one is recovered by ReconcileAlertDeliveriesJob after DELIVERY_LEASE.
    STATUSES = %w[pending delivering sent failed skipped collapsed summarized].freeze
    TERMINAL_STATUSES = %w[sent failed skipped summarized].freeze

    attr_accessor :suppress_auto_enqueue

    before_validation :inherit_integration, on: :create
    before_validation :assign_delivery_metadata, on: :create
    after_create_commit :enqueue_initial_work, unless: :suppress_auto_enqueue

    # How far back reconciliation looks. An alert older than this that is
    # still pending or collapsed predates the outbox (a row an old container
    # wrote, or one left over from before this shipped); delivering it now
    # would page someone about something that happened hours ago.
    RECONCILE_WINDOW = 1.hour

    scope :due_for_delivery, ->(now = Time.current) {
      where(status: "pending").where(created_at: (now - RECONCILE_WINDOW)..)
        .where("next_delivery_at IS NULL OR next_delivery_at <= ?", now)
        .where("delivery_enqueued_until IS NULL OR delivery_enqueued_until <= ?", now)
    }
    scope :with_stale_delivery_lease, ->(now = Time.current) {
      where(status: "delivering").where("delivery_lease_expires_at <= ?", now)
    }
    scope :overdue_collapsed, ->(now = Time.current) {
      where(status: "collapsed").where(created_at: (now - RECONCILE_WINDOW)..(now - AlertRule::BURST_WINDOW))
    }

    # Reserve a queue hand-off. If the process dies after this write and before
    # perform_later, reconciliation retries once this short reservation expires.
    def enqueue_delivery!(wait_until: nil)
      reserved_until = nil
      target = nil
      with_lock do
        return false unless status == "pending"

        target = [ wait_until, next_delivery_at, Time.current ].compact.max
        return false if delivery_enqueued_until&.future?

        reserved_until = target + ENQUEUE_LEASE
        update!(delivery_enqueued_until: reserved_until)
      end

      if target.future?
        DeliverAlertJob.set(wait_until: target).perform_later(self)
      else
        DeliverAlertJob.perform_later(self)
      end
      true
    rescue StandardError
      Alert.where(id: id, status: "pending", delivery_enqueued_until: reserved_until)
        .update_all(delivery_enqueued_until: nil, updated_at: Time.current) if reserved_until
      raise
    end

    # Atomically turns one queued job into the only worker allowed to deliver.
    # Duplicate jobs and jobs for terminal alerts return nil without I/O.
    def claim_delivery!
      with_lock do
        return unless status == "pending"
        return if next_delivery_at.present? && next_delivery_at.future?

        token = SecureRandom.uuid
        update!(status: "delivering", delivery_attempts: delivery_attempts + 1,
          delivery_key: delivery_key.presence || SecureRandom.uuid,
          delivery_lease_id: token, delivery_lease_expires_at: DELIVERY_LEASE.from_now,
          delivery_enqueued_until: nil)
        token
      end
    end

    def perform_claimed_delivery!(token)
      if integration.enabled?
        integration.deliver(self)
        finish_claim!(token, "sent")
      else
        finish_claim!(token, "skipped")
      end
    end

    # Persists retry intent before another job is scheduled. A crash at the
    # following queue boundary is recovered by ReconcileAlertDeliveriesJob.
    def fail_claim!(token, exception)
      message = "#{exception.class}: #{exception.message}".first(1000)
      retry_at = nil
      with_lock do
        return unless owns_delivery_claim?(token)

        if delivery_attempts >= MAX_DELIVERY_ATTEMPTS
          update!(status: "failed", error: message, next_delivery_at: nil,
            delivery_lease_id: nil, delivery_lease_expires_at: nil, delivery_enqueued_until: nil)
        else
          retry_at = RETRY_DELAYS.fetch(delivery_attempts - 1).from_now
          update!(status: "pending", error: message, next_delivery_at: retry_at,
            delivery_lease_id: nil, delivery_lease_expires_at: nil, delivery_enqueued_until: nil)
        end
        integration.update_columns(last_error: message)
      end
      retry_at
    end

    # A lease expiry is indistinguishable from a worker dying after the remote
    # endpoint accepted the message but before `sent` committed. Retrying is
    # required for at-least-once delivery; webhook consumers can deduplicate by
    # delivery_key / Idempotency-Key.
    def recover_stale_delivery!
      retryable = false
      with_lock do
        return false unless status == "delivering" && delivery_lease_expires_at&.past?

        message = error.presence || "Delivery lease expired before completion"
        if delivery_attempts >= MAX_DELIVERY_ATTEMPTS
          update!(status: "failed", error: message, next_delivery_at: nil,
            delivery_lease_id: nil, delivery_lease_expires_at: nil, delivery_enqueued_until: nil)
        else
          update!(status: "pending", error: message, next_delivery_at: Time.current,
            delivery_lease_id: nil, delivery_lease_expires_at: nil, delivery_enqueued_until: nil)
          retryable = true
        end
      end
      retryable
    end

    # Explicit operator action: terminal failures get a fresh, bounded attempt
    # budget. Sent/skipped alerts are intentionally not replayed by this path.
    def retry_delivery!
      with_lock do
        return false unless status == "failed"

        update!(status: "pending", error: nil, delivery_attempts: 0,
          next_delivery_at: Time.current, delivery_enqueued_until: nil,
          delivery_lease_id: nil, delivery_lease_expires_at: nil)
      end
      enqueue_delivery!
    end

    # Synchronous delivery is retained for "Send test", whose HTTP response
    # must report the real destination outcome. Normal alerts use the leased job
    # path above.
    def deliver!
      return self if TERMINAL_STATUSES.include?(status)
      return update!(status: "skipped") unless integration.enabled?

      integration.deliver(self)
      mark_sent!
      self
    rescue StandardError => e
      message = "#{e.class}: #{e.message}".first(1000)
      update!(status: "failed", error: message)
      integration.update_columns(last_error: message)
      raise
    end

    private

    def enqueue_initial_work
      if status == "pending"
        enqueue_delivery!
      elsif status == "collapsed" && alert_rule
        SummarizeAlertBurstJob.set(wait_until: created_at + AlertRule::BURST_WINDOW).perform_later(alert_rule)
      end
    end

    def assign_delivery_metadata
      self.delivery_key ||= SecureRandom.uuid
      self.next_delivery_at ||= Time.current if status.blank? || status == "pending"
    end

    def inherit_integration
      self.integration ||= alert_rule&.integration
    end

    def owns_delivery_claim?(token)
      status == "delivering" && delivery_lease_id == token
    end

    def finish_claim!(token, outcome)
      with_lock do
        return false unless owns_delivery_claim?(token)

        attributes = { status: outcome, error: nil, next_delivery_at: nil,
                      delivery_lease_id: nil, delivery_lease_expires_at: nil,
                      delivery_enqueued_until: nil }
        attributes[:sent_at] = Time.current if outcome == "sent"
        update!(attributes)
        if outcome == "sent"
          integration.update_columns(last_delivered_at: Time.current, last_error: nil)
          issue&.activities&.create!(kind: "alert", data: { event: event, integration: integration.kind })
        end
        true
      end
    end

    def mark_sent!
      update!(status: "sent", sent_at: Time.current, error: nil)
      integration.update_columns(last_delivered_at: Time.current, last_error: nil)
      issue&.activities&.create!(kind: "alert", data: { event: event, integration: integration.kind })
    end
  end
end
