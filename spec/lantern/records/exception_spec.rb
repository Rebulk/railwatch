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

  describe "ignored_exceptions" do
    # Around a config change, so a leaked list can't silence later examples.
    def with_ignored(list)
      original = Lantern.config.ignored_exceptions
      Lantern.config.ignored_exceptions = list
      yield
    ensure
      Lantern.config.ignored_exceptions = original
    end

    # Rails never reports an exception with a rescue_response (RecordNotFound
    # -> 404) to Rails.error, so the interesting path for these is a job or an
    # explicit report, not a request.
    def report_missing_widget
      Lantern.start_execution(source: :job, sample_kind: :jobs)
      Lantern.report(ActiveRecord::RecordNotFound.new("Couldn't find Widget with 'id'=999"), handled: true)
      Lantern.finish_execution
    end

    it "drops ActiveRecord::RecordNotFound, which the default list carries over from Sentry" do
      expect(Lantern.config.ignored_exceptions).to include("ActiveRecord::RecordNotFound")

      report_missing_widget

      expect(lantern_records(:exception)).to be_empty
    end

    it "captures that same error once it is removed from the list" do
      with_ignored(Lantern.config.ignored_exceptions - [ "ActiveRecord::RecordNotFound" ]) { report_missing_widget }

      expect(lantern_records(:exception).sole[:class]).to eq("ActiveRecord::RecordNotFound")
    end

    it "drops a subclass of an ignored exception, not just an exact class match" do
      subclass = Class.new(ArgumentError)
      stub_const("IgnoredSubclass", subclass)

      with_ignored([ "ArgumentError" ]) do
        Lantern.start_execution(source: :command, sample_kind: :commands)
        Lantern.report(IgnoredSubclass.new("child of an ignored class"), handled: true)
        Lantern.finish_execution
      end

      expect(lantern_records(:exception)).to be_empty
    end

    it "drops an unhandled exception too, not only handled ones" do
      with_ignored([ "ArgumentError" ]) { get "/boom" }

      expect(response).to have_http_status(:internal_server_error)
      expect(lantern_records(:exception)).to be_empty
    end

    it "leaves an unlisted exception alone" do
      with_ignored([ "SomeOtherError" ]) { get "/handled" }

      expect(lantern_records(:exception).sole[:class]).to eq("RuntimeError")
    end
  end

  it "captures redacted local variables at the raise site when capture_exception_locals is on" do
    Lantern.config.capture_exception_locals = true
    Lantern::Subscribers::Exceptions::Locals.install!
    begin
      Lantern.start_execution(source: :command, sample_kind: :commands)
      begin
        widget_id = 42
        password = "hunter2"
        raise ArgumentError, "with locals #{widget_id} #{password.size}"
      rescue ArgumentError => e
        Rails.error.report(e, handled: true)
      end
      Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

      locals = lantern_records(:exception).sole[:locals]
      expect(locals["widget_id"]).to eq("42")
      expect(locals["password"]).to eq("[FILTERED]")
    ensure
      Lantern::Subscribers::Exceptions::Locals.uninstall!
      Lantern.config.capture_exception_locals = false
    end
  end
end
