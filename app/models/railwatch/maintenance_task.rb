# frozen_string_literal: true

module Railwatch
  # One row per maintenance task (Railwatch::Maintenance::TASKS): when it last
  # ran and who holds it now. Every process on the host runs the maintenance
  # clock; this is how exactly one of them runs each task. The claim is a
  # single conditional UPDATE, so SQLite's write lock is the arbiter and there
  # is no window between checking and taking the lease.
  class MaintenanceTask < ApplicationRecord
    self.table_name = "railwatch_maintenance_tasks"

    # The token for a claim this process won, or nil: the task is due
    # (last_run_at older than `every`, or never) and nobody holds a live
    # lease on it. A lease left by a process that died expires on its own.
    # The token is per claim, not per process, so a claim that outlived its
    # lease cannot later release the lease the next claimant holds.
    def self.claim(name, every:, lease:, owner:, now: Time.current)
      ensure_row(name)
      token = "#{owner}:#{SecureRandom.hex(8)}"
      won = where(name: name)
        .where("lease_expires_at IS NULL OR lease_expires_at < ?", now)
        .where("last_run_at IS NULL OR last_run_at <= ?", now - every)
        .update_all(lease_owner: token, lease_expires_at: now + lease, updated_at: now) == 1
      won ? token : nil
    end

    # Releases only the lease this token holds. A task that succeeded records
    # the run so the interval starts again; one that failed records nothing,
    # so it is eligible on the next tick rather than a full interval later.
    def self.release(name, token:, ran_at:, succeeded:)
      changes = { lease_owner: nil, lease_expires_at: nil, updated_at: ran_at }
      changes[:last_run_at] = ran_at if succeeded
      where(name: name, lease_owner: token).update_all(changes)
    end

    # The newest tick across every task: what the doctor reports as "last
    # maintenance", and the signal that the clock is alive somewhere.
    def self.last_tick_at
      maximum(:last_run_at)
    end

    # Two processes racing to create the same row: one loses on the unique
    # index, and the row it wanted now exists.
    def self.ensure_row(name)
      return if exists?(name: name)

      create!(name: name)
    rescue ActiveRecord::RecordNotUnique
      nil
    end
    private_class_method :ensure_row
  end
end
