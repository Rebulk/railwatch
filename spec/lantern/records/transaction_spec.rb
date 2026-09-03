# frozen_string_literal: true

require "spec_helper"

RSpec.describe "transaction record" do
  def finish!
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "reports outcome commit, connection, group, and statement_count for a committed transaction" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    ActiveRecord::Base.transaction do
      Widget.create!(name: "a")
      Widget.create!(name: "b")
    end
    finish!

    txn = lantern_records(:transaction).sole
    expect(txn[:outcome]).to eq("commit")
    expect(txn[:connection]).to eq("primary")
    expect(txn[:statement_count]).to eq(2)
    expect(txn[:duration]).to be_a(Integer).and be >= 0
    expect(txn[:_group]).to be_a(String)
  end

  it "reports outcome rollback when the block raises" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    expect do
      ActiveRecord::Base.transaction do
        Widget.create!(name: "a")
        raise ActiveRecord::Rollback
      end
    end.not_to raise_error
    finish!

    txn = lantern_records(:transaction).sole
    expect(txn[:outcome]).to eq("rollback")
    expect(txn[:statement_count]).to eq(1)
  end
end
