# frozen_string_literal: true

# `attributes` is Active Record's own method; a column by that name raises
# DangerousAttributeError on first access. The wire key stays "attributes",
# Ingest::Mapper writes it to payload.
class RenameSpanAttributesToPayload < ActiveRecord::Migration[8.1]
  def change
    rename_column :spans, :attributes, :payload
  end
end
