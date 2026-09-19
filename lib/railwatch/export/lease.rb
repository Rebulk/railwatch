# frozen_string_literal: true

module Railwatch
  module Export
    # Which process is allowed to send, right now.
    #
    # Every eligible process runs a sender; the lease decides which one does
    # anything. It is held for a short time and renewed, so a process that
    # dies holding it blocks the queue for seconds rather than forever.
    #
    # The generation is a fence. A holder that stalls past its expiry may wake
    # and finish a request it had already started -- the receipt at the other
    # end makes that harmless -- but it must not then be able to overwrite
    # what the new holder has since recorded. Every write it attempts carries
    # the generation it was granted, and a stale one matches nothing.
    module Lease
      TTL = 30
      # Renewed well inside the TTL: a renewal that has to wait on the write
      # lock still has room to land before the lease it is extending lapses.
      RENEW_EVERY = 10

      module_function

      # Takes the lease, or extends it if we already hold it. Returns the
      # generation we hold it under, or nil if someone else has it.
      def acquire(destination_id, owner:, now: Time.current)
        taken = Telemetry::ExportDestination
          .where(id: destination_id)
          .where("lease_owner IS NULL OR lease_owner = ? OR lease_expires_at < ?", owner, now)
          .update_all([
            "lease_owner = ?, lease_expires_at = ?, lease_generation = lease_generation + 1, updated_at = ?",
            owner, now + TTL, now
          ])
        return nil if taken.zero?

        Telemetry::ExportDestination.where(id: destination_id).pick(:lease_generation)
      end

      # Extends a lease we still hold. Cannot revive an expired one: taking it
      # again is acquire's job, and that increments the generation so anything
      # in flight under the old one is fenced out.
      def renew(destination_id, owner:, generation:, now: Time.current)
        Telemetry::ExportDestination
          .where(id: destination_id, lease_owner: owner, lease_generation: generation)
          .where(lease_expires_at: now..)
          .update_all([ "lease_expires_at = ?, updated_at = ?", now + TTL, now ]) == 1
      end

      def release(destination_id, owner:, generation:, now: Time.current)
        Telemetry::ExportDestination
          .where(id: destination_id, lease_owner: owner, lease_generation: generation)
          .update_all([ "lease_owner = NULL, lease_expires_at = NULL, updated_at = ?", now ]) == 1
      end
    end
  end
end
