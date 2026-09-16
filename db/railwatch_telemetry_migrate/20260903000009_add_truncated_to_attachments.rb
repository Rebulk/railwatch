# frozen_string_literal: true

# The gem cuts an attachment off at its size limit and flags the wire
# record; without this column the UI cannot tell a whole file from a stub.
class AddTruncatedToAttachments < ActiveRecord::Migration[8.1]
  def change
    add_column :attachments, :truncated, :boolean, default: false, null: false
  end
end
