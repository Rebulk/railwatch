# frozen_string_literal: true

# Outbox#claim! reclaims abandoned claims inside every claim transaction:
# `state = 'sending' AND claim_expires_at < now` for the destination. No
# index covered it, so SQLite walked index_export_deliveries_on_export_destination_id
# -- every row the destination has ever had, done ones included, which
# prune! keeps for eight days. In production that was 270 ms of a ~500 ms
# delivery, held under the write lock, on a table of 344k rows (330k done),
# and it grew with everything the queue had ever sent.
#
# At most one row is ever sending (the lease is one in flight), so this
# index holds zero or one entry and the reclaim, and release_lease!'s
# "anything still sending?", cost the same however much has been sent.
class AddSendingIndexToExportDeliveries < ActiveRecord::Migration[8.1]
  def change
    add_index :export_deliveries, %i[export_destination_id claim_expires_at], where: "state = 'sending'",
      name: "index_export_deliveries_sending"
  end
end
