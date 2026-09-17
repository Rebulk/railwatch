# frozen_string_literal: true

module Railwatch
  # One row per maintenance task (Railwatch::Maintenance::TASKS): when it last
  # ran and who holds it now. Every process on the host runs the maintenance
  # clock; this is how exactly one of them runs each task. The claim is a
  # single conditional UPDATE, so SQLite's write lock is the arbiter and there
  # is no window between checking and taking the lease.
  class MaintenanceTask < ApplicationRecord
    self.table_name = "railwatch_maintenance_tasks"

    # True when this process won the right to run `name` now: the task is
    # due (last_run_at older than `every`, or never) and nobody holds a live
    # lease on it. A lease left by a process that died expires on its own.
    def self.claim(name, every:, lease:, owner:, now: Time.current)
      ensure_row(name)
      where(name: name)
        .where("lease_expires_at IS NULL OR lease_expires_at < ?", now)
        .where("last_run_at IS NULL OR last_run_at <= ?", now - every)
        .update_all(lease_owner: owner, lease_expires_at: now + lease, updated_at: now) == 1
    end

    def self.release(name, ran_at:)
      where(name: name).update_all(last_run_at: ran_at, lease_owner: nil, lease_expires_at: nil, updated_at: ran_at)
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
