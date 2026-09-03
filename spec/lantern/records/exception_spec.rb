# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exception record", type: :request do
  it "captures class, message, handled, severity, source, file, line, and frames for an unhandled error" do
    get "/boom"

    ex = lantern_records(:exception).sole
    expect(ex[:class]).to eq("ArgumentError")
    expect(ex[:message]).to eq("kaboom")
    expect(ex[:handled]).to be(false)
    expect(ex[:severity]).to eq("error")
    # Rails' own ActionDispatch exception handling reports to Rails.error
    # before the error propagates up to Lantern's outer middleware rescue,
    # and Lantern's dedupe (Exceptions.seen?) means whichever capture fires
    # first -- here, the Rails.error subscriber -- is the one that ships.
    expect(ex[:source]).to eq("application.action_dispatch")
    expect(ex[:file]).to include("widgets_controller.rb")
    expect(ex[:line]).to be_a(Integer)
    expect(ex[:frames]).to be_an(Array)
    expect(ex[:frames].first).to include(:file, :line, :function, :in_app)
    expect(ex[:ruby_version]).to eq(RUBY_VERSION)
    expect(ex[:rails_version]).to eq(Rails.version)
  end

  it "captures a handled error reported via Rails.error.handle as severity warning" do
    get "/handled"

    ex = lantern_records(:exception).sole
    expect(ex[:class]).to eq("RuntimeError")
    expect(ex[:message]).to eq("swallowed")
    expect(ex[:handled]).to be(true)
    expect(ex[:severity]).to eq("warning")
  end

  it "captures cause when the error was raised from a rescue block" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    begin
      begin
        raise "root cause"
      rescue RuntimeError
        raise "wrapper error"
      end
    rescue RuntimeError => e
      Lantern.report(e, handled: true)
    end
    Lantern.finish_execution

    ex = lantern_records(:exception).sole
    expect(ex[:cause]).to eq(class: "RuntimeError", message: "root cause")
  end

  it "dedupes the same error object reported twice (middleware catch + Rails.error re-report)" do
    error = ArgumentError.new("dup me")
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern.report(error, handled: true)
    Lantern.report(error, handled: true)
    Lantern.finish_execution

    expect(lantern_records(:exception).size).to eq(1)
  end

  it "captures the sql_state from the underlying driver error for a StatementInvalid" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    begin
      ActiveRecord::Base.connection.execute("SELECT * FROM no_such_table")
    rescue ActiveRecord::StatementInvalid => e
      Lantern.report(e, handled: true)
    end
    Lantern.finish_execution

    ex = lantern_records(:exception).sole
    expect(ex[:class]).to eq("ActiveRecord::StatementInvalid")
    expect(ex[:sql_state]).to be_nil # sqlite3's adapter error does not expose #sql_state
  end
end
