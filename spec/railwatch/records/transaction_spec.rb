# frozen_string_literal: true

require "spec_helper"

RSpec.describe "transaction record" do
  def finish!
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "reports outcome commit, connection, group, and statement_count for a committed transaction" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    ActiveRecord::Base.transaction do
      Widget.create!(name: "a")
      Widget.create!(name: "b")
    end
    finish!

    txn = railwatch_records(:transaction).sole
    expect(txn[:outcome]).to eq("commit")
    expect(txn[:connection]).to eq("primary")
    expect(txn[:statement_count]).to eq(2)
    expect(txn[:duration]).to be_a(Integer).and be >= 0
    expect(txn[:_group]).to be_a(String)
  end

  it "keeps no per-transaction statement counts once a sampled-out execution's transactions end" do
    # Statements are counted for every execution, so the count must also be
    # taken back for every execution: a sampled-out job looping over
    # transactions would otherwise hold one entry per transaction until it
    # finished.
    exe = Railwatch.start_execution(source: :command, sample_kind: :commands)
    exe.sampled = false
    3.times { ActiveRecord::Base.transaction { Widget.create!(name: "a") } }
    expect(exe.instance_variable_get(:@transaction_statement_counts)).to be_empty
    finish!

    expect(railwatch_records(:transaction)).to be_empty
  end

  it "reports outcome rollback when the block raises" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    expect do
      ActiveRecord::Base.transaction do
        Widget.create!(name: "a")
        raise ActiveRecord::Rollback
      end
    end.not_to raise_error
    finish!

    txn = railwatch_records(:transaction).sole
    expect(txn[:outcome]).to eq("rollback")
    expect(txn[:statement_count]).to eq(1)
  end
end
