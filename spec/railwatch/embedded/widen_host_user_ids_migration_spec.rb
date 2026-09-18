# frozen_string_literal: true

require "spec_helper"
require Railwatch.migrations_path(:railwatch) + "/20260918120000_widen_host_user_ids.rb"

# Rolling this back turns an opaque id into an integer, which a UUID or an
# email has no form of. The down path therefore refuses rather than coercing,
# because a coerced id is silently a different person.
RSpec.describe WidenHostUserIds do
  # A migration talks to ActiveRecord::Base's connection, which in this suite
  # is the dummy app's primary database, not the one these tables live in.
  # The migrator repoints that for the duration of a real run; here the
  # migration is pointed at the engine's own connection instead, because a
  # second connection cannot read rows this example has written and not yet
  # committed, and SQLite answers that with "database is locked".
  def migration
    described_class.new.tap do |m|
      m.verbose = false
      allow(m).to receive(:connection).and_return(Railwatch::ApplicationRecord.connection)
    end
  end

  def with_saved_view(viewer_id)
    Railwatch::SavedView.create!(name: "V", page: "requests", environment_id: 1, viewer_id: viewer_id)
    yield
  ensure
    Railwatch::SavedView.delete_all
  end

  it "rolls back when every stored id is still a number" do
    with_saved_view("7") do
      subject = migration
      expect { subject.down }.not_to raise_error
      expect(column_type(:railwatch_saved_views, :viewer_id)).to match(/int/i)
      subject.up
    end
    expect(column_type(:railwatch_saved_views, :viewer_id)).to match(/varchar|char|text/i)
  end

  it "refuses, naming the ids, when one of them has no integer form" do
    with_saved_view("018f3a2b-9c4d-7e1f-8a2b-3c4d5e6f7a8b") do
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /018f3a2b/)
    end
    # And the column is untouched, not half-narrowed.
    expect(column_type(:railwatch_saved_views, :viewer_id)).to match(/varchar|char|text/i)
  end

  def column_type(table, column)
    Railwatch::ApplicationRecord.connection.columns(table.to_s).find { |c| c.name == column.to_s }.sql_type
  end
end
