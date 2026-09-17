# frozen_string_literal: true

module Railwatch
  # One row per (batch, exception group) whose occurrences have been counted
  # onto an issue. Lives beside the issues, in the same database and the same
  # transaction as the count, so "did this batch's exceptions already reach
  # this issue" has exactly one answer however many times the follow-up runs.
  class FollowupReceipt < ApplicationRecord
    self.table_name = "railwatch_followup_receipts"

    # Receipts outlive their batch's ledger row by this much; a replay after
    # that is one the ledger no longer knows about either.
    RETENTION = 30.days

    # True when this call is the first for the pair: the caller's work is
    # owed. False when a receipt already exists: the work was done, skip it.
    # Must run inside a transaction on this database with the work itself.
    def self.claim!(batch_id:, group_hash:)
      insert({ batch_id: batch_id, group_hash: group_hash, created_at: Time.current },
             unique_by: %i[batch_id group_hash]).rows.any?
    end

    def self.prune!(now: Time.current)
      where(created_at: ...(now - RETENTION)).delete_all
    end
  end
end
