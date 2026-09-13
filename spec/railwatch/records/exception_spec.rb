# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exception record", type: :request do
  it "captures class, message, handled, severity, source, file, line, and frames for an unhandled error" do
    get "/boom"

    ex = railwatch_records(:exception).sole
    expect(ex[:class]).to eq("ArgumentError")
    expect(ex[:message]).to eq("kaboom")
    expect(ex[:handled]).to be(false)
    expect(ex[:severity]).to eq("error")
    # Rails' own ActionDispatch exception handling reports to Rails.error
    # before the error propagates up to Railwatch's outer middleware rescue,
    # and Railwatch's dedupe (Exceptions.seen?) means whichever capture fires
    # first -- here, the Rails.error subscriber -- is the one that ships.
    expect(ex[:source]).to eq("application.action_dispatch")
    expect(ex[:file]).to include("widgets_controller.rb")
    expect(ex[:line]).to be_a(Integer)
    expect(ex[:frames]).to be_an(Array)
    expect(ex[:frames].first).to include(:file, :line, :function, :in_app)
    expect(ex[:ruby_version]).to eq(RUBY_VERSION)
    expect(ex[:rails_version]).to eq(Rails.version)
  end

  it "groups on the default fingerprint -- class, top in-app frame, normalized message -- and says so" do
    get "/boom"

    ex = railwatch_records(:exception).sole
    expect(ex[:fingerprint]).to eq([ "ArgumentError", ex[:file], ex[:line].to_s, "kaboom" ])
    expect(ex[:fingerprint_source]).to eq("default")
    expect(ex[:_group]).to eq(Railwatch::Record.group_hash(*ex[:fingerprint]))
  end

  it "captures a handled error reported via Rails.error.handle as severity warning" do
    get "/handled"

    ex = railwatch_records(:exception).sole
    expect(ex[:class]).to eq("RuntimeError")
    expect(ex[:message]).to eq("swallowed")
    expect(ex[:handled]).to be(true)
    expect(ex[:severity]).to eq("warning")
  end

  it "captures cause when the error was raised from a rescue block" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    begin
      begin
        raise "root cause"
      rescue RuntimeError
        raise "wrapper error"
      end
    rescue RuntimeError => e
      Railwatch.report(e, handled: true)
    end
    Railwatch.finish_execution

    ex = railwatch_records(:exception).sole
    expect(ex[:cause]).to eq(class: "RuntimeError", message: "root cause")
  end

  it "dedupes the same error object reported twice (middleware catch + Rails.error re-report)" do
    error = ArgumentError.new("dup me")
    exe = Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch.report(error, handled: true)
    Railwatch.report(error, handled: true)
    Railwatch.finish_execution

    expect(railwatch_records(:exception).size).to eq(1)
    expect(exe.counters[:exceptions]).to eq(1)
    expect(exe.exception_preview).to eq("ArgumentError: dup me")
  end

  it "does not let a sampled-out handled capture suppress a later unhandled capture" do
    error = ArgumentError.new("becomes fatal")
    exe = Railwatch.start_execution(source: :command, sample_kind: :commands)
    exe.sampled = false

    Railwatch.report(error, handled: true)
    Railwatch.report(error, handled: false)
    Railwatch.finish_execution

    expect(railwatch_records(:exception).sole).to include(message: "becomes fatal", handled: false)
  end

  it "does not let a paused handled capture suppress a later unhandled capture" do
    error = ArgumentError.new("visible after resume")
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch.pause
    Railwatch.report(error, handled: true)
    Railwatch.resume

    Railwatch.report(error, handled: false)
    Railwatch.finish_execution

    expect(railwatch_records(:exception).sole).to include(message: "visible after resume", handled: false)
  end

  it "captures handled and unhandled observations as distinct dispositions" do
    error = ArgumentError.new("changed disposition")
    Railwatch.start_execution(source: :command, sample_kind: :commands)

    Railwatch.report(error, handled: true)
    Railwatch.report(error, handled: false)
    Railwatch.finish_execution

    expect(railwatch_records(:exception).map { |record| record[:handled] }).to contain_exactly(true, false)
  end

  it "captures a reused exception object once in each execution" do
    error = ArgumentError.new("reused")

    2.times do
      Railwatch.start_execution(source: :command, sample_kind: :commands)
      Railwatch.report(error, handled: true)
      Railwatch.finish_execution
    end

    expect(railwatch_records(:exception).map { |record| record[:message] }).to eq([ "reused", "reused" ])
  end

  it "keeps an outer execution deduped across many nested executions" do
    error = ArgumentError.new("nested reuse")
    outer = Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch.report(error, handled: true)

    5.times do
      Railwatch.start_execution(source: :job, sample_kind: :jobs)
      Railwatch.report(error, handled: true)
      Railwatch.finish_execution
    end

    Railwatch.report(error, handled: true)
    Railwatch.finish_execution

    outer_records = railwatch_records(:exception).select { |record| record[:execution_id] == outer.id }
    expect(outer_records.size).to eq(1)
    expect(outer.counters[:exceptions]).to eq(1)
  end

  it "captures the sql_state from the underlying driver error for a StatementInvalid" do
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    begin
      ActiveRecord::Base.connection.execute("SELECT * FROM no_such_table")
    rescue ActiveRecord::StatementInvalid => e
      Railwatch.report(e, handled: true)
    end
    Railwatch.finish_execution

    ex = railwatch_records(:exception).sole
    expect(ex[:class]).to eq("ActiveRecord::StatementInvalid")
    expect(ex[:sql_state]).to be_nil # sqlite3's adapter error does not expose #sql_state
  end

  describe "ignored_exceptions" do
    # Around a config change, so a leaked list can't silence later examples.
    def with_ignored(list)
      original = Railwatch.config.ignored_exceptions
      Railwatch.config.ignored_exceptions = list
      yield
    ensure
      Railwatch.config.ignored_exceptions = original
    end

    # Rails never reports an exception with a rescue_response (RecordNotFound
    # -> 404) to Rails.error, so the interesting path for these is a job or an
    # explicit report, not a request.
    def report_missing_widget
      Railwatch.start_execution(source: :job, sample_kind: :jobs)
      Railwatch.report(ActiveRecord::RecordNotFound.new("Couldn't find Widget with 'id'=999"), handled: true)
      Railwatch.finish_execution
    end

    it "drops ActiveRecord::RecordNotFound, which the default list carries over from Sentry" do
      expect(Railwatch.config.ignored_exceptions).to include("ActiveRecord::RecordNotFound")

      report_missing_widget

      expect(railwatch_records(:exception)).to be_empty
    end

    it "captures that same error once it is removed from the list" do
      with_ignored(Railwatch.config.ignored_exceptions - [ "ActiveRecord::RecordNotFound" ]) { report_missing_widget }

      expect(railwatch_records(:exception).sole[:class]).to eq("ActiveRecord::RecordNotFound")
    end

    it "drops a subclass of an ignored exception, not just an exact class match" do
      subclass = Class.new(ArgumentError)
      stub_const("IgnoredSubclass", subclass)

      with_ignored([ "ArgumentError" ]) do
        Railwatch.start_execution(source: :command, sample_kind: :commands)
        Railwatch.report(IgnoredSubclass.new("child of an ignored class"), handled: true)
        Railwatch.finish_execution
      end

      expect(railwatch_records(:exception)).to be_empty
    end

    it "drops an unhandled exception too, not only handled ones" do
      with_ignored([ "ArgumentError" ]) { get "/boom" }

      expect(response).to have_http_status(:internal_server_error)
      expect(railwatch_records(:exception)).to be_empty
    end

    it "leaves an unlisted exception alone" do
      with_ignored([ "SomeOtherError" ]) { get "/handled" }

      expect(railwatch_records(:exception).sole[:class]).to eq("RuntimeError")
    end
  end

  it "captures redacted local variables at the raise site when capture_exception_locals is on" do
    Railwatch.config.capture_exception_locals = true
    Railwatch::Subscribers::Exceptions::Locals.install!
    begin
      Railwatch.start_execution(source: :command, sample_kind: :commands)
      begin
        widget_id = 42
        password = "hunter2"
        raise ArgumentError, "with locals #{widget_id} #{password.size}"
      rescue ArgumentError => e
        Rails.error.report(e, handled: true)
      end
      Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

      locals = railwatch_records(:exception).sole[:locals]
      expect(locals["widget_id"]).to eq("42")
      expect(locals["password"]).to eq("[FILTERED]")
    ensure
      Railwatch::Subscribers::Exceptions::Locals.uninstall!
      Railwatch.config.capture_exception_locals = false
    end
  end

  it "falls back to the class when a local value's inspect raises" do
    explosive = stub_const("ExplosiveInspect", Class.new do
      def inspect
        raise "inspect failed"
      end
    end)

    value = Railwatch::Subscribers::Exceptions::Locals.inspect_value(explosive.new)

    expect(value).to eq("#<ExplosiveInspect>")
  end
end
