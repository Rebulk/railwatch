# frozen_string_literal: true

require "spec_helper"
require "timeout"

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

  # The name `attrs` is not sensitive, so the filter over local NAMES passes
  # it; what is inside it has to be filtered by key before it is one string.
  describe "a local that holds keyed data" do
    def captured_locals
      Railwatch.config.capture_exception_locals = true
      Railwatch::Subscribers::Exceptions::Locals.install!
      Railwatch.start_execution(source: :command, sample_kind: :commands)
      begin
        yield
      rescue ArgumentError => e
        Rails.error.report(e, handled: true)
      end
      Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
      railwatch_records(:exception).sole[:locals]
    ensure
      Railwatch::Subscribers::Exceptions::Locals.uninstall!
      Railwatch.config.capture_exception_locals = false
    end

    it "masks a filtered key inside a hash, whether the key is a string or a symbol" do
      locals = captured_locals do
        attrs = { "email" => "a@example.test", "password" => "hunter2", secret_code: "s3cret" }
        raise ArgumentError, "with a hash #{attrs.size}"
      end

      expect(locals["attrs"]).to include("a@example.test", "[FILTERED]")
      expect(locals["attrs"]).not_to include("hunter2", "s3cret")
    end

    it "masks a filtered key nested in hashes and arrays" do
      locals = captured_locals do
        rows = [ { user: { name: "Ada", password: "hunter2" } }, { "password" => "hunter3" } ]
        raise ArgumentError, "with rows #{rows.size}"
      end

      expect(locals["rows"]).to include("Ada", "[FILTERED]")
      expect(locals["rows"]).not_to include("hunter2", "hunter3")
    end

    it "masks a filtered key inside request parameters" do
      locals = captured_locals do
        permitted = ActionController::Parameters.new(user: { email: "a@example.test", password: "hunter2" })
        raise ArgumentError, "with params #{permitted.keys.size}"
      end

      expect(locals["permitted"]).to include("a@example.test", "[FILTERED]")
      expect(locals["permitted"]).not_to include("hunter2")
    end

    it "leaves the local's own data alone" do
      attrs = { "name" => "Ada", "nested" => { "password" => "hunter2" } }

      Railwatch::Subscribers::Exceptions::Locals.inspect_value(attrs)

      expect(attrs).to eq("name" => "Ada", "nested" => { "password" => "hunter2" })
    end

    it "ends a structure that contains itself" do
      cycle = { "name" => "Ada", "password" => "hunter2" }
      cycle["self"] = cycle

      value = Railwatch::Subscribers::Exceptions::Locals.inspect_value(cycle)

      expect(value).to include("Ada", "[FILTERED]", "…")
      expect(value).not_to include("hunter2")
    end

    it "reads a large hash exactly as before, up to the length it keeps" do
      big = (1..500).to_h { |n| [ "k#{n}", n ] }

      value = Railwatch::Subscribers::Exceptions::Locals.inspect_value(big)

      expect(value).to eq(big.inspect[0, 200] + "…")
    end

    # Scrubbing runs while an exception is being reported: it must return,
    # promptly, and raise nothing, whatever the local holds.
    def promptly(&)
      Timeout.timeout(2, &)
    end

    it "ends request parameters that contain themselves" do
      params = ActionController::Parameters.new(name: "Ada", password: "hunter2")
      params[:self] = params

      value = nil
      expect { promptly { value = Railwatch::Subscribers::Exceptions::Locals.inspect_value(params) } }.not_to raise_error

      expect(value).to include("Ada", "[FILTERED]", "…")
      expect(value).not_to include("hunter2")
    end

    it "does not convert all of a large params object before keeping the first entries" do
      params = ActionController::Parameters.new((1..500).to_h { |n| [ "k#{n}", { "n" => n } ] })
      expect(params).not_to receive(:to_unsafe_h)

      scrubbed = Railwatch.redactor.scrub(params)

      expect(scrubbed.size).to eq(Railwatch::Redactor::SCRUB_MAX_ENTRIES)
      expect(scrubbed["k1"]).to eq("n" => 1)
    end

    it "does not expand an array that holds itself a hundred times once per path" do
      a = []
      100.times { a << a }

      value = nil
      expect { promptly { value = Railwatch::Subscribers::Exceptions::Locals.inspect_value(a) } }.not_to raise_error

      expect(value).to start_with("[…, …")
    end

    it "bounds a structure that holds the same container many times without a cycle" do
      level = { "password" => "hunter2", "name" => "Ada" }
      4.times { level = Array.new(100) { level } }
      keys_read = 0
      allow(Railwatch.redactor).to receive(:scrub_key?).and_wrap_original do |original, *args|
        keys_read += 1
        original.call(*args)
      end

      value = nil
      expect { promptly { value = Railwatch::Subscribers::Exceptions::Locals.inspect_value(level) } }.not_to raise_error

      expect(keys_read).to be <= 2 * Railwatch::Redactor::SCRUB_MAX_NODES
      expect(value).to include("[FILTERED]", "Ada")
      expect(value).not_to include("hunter2")
    end

    it "scrubs ordinary nested values exactly as before" do
      value = { "user" => { "name" => "Ada", "password" => "hunter2", "tags" => [ "a", { "secret_code" => "s" } ] }, "n" => 1 }

      expect(Railwatch.redactor.scrub(value)).to eq(
        "user" => { "name" => "Ada", "password" => "[FILTERED]", "tags" => [ "a", { "secret_code" => "[FILTERED]" } ] }, "n" => 1
      )
    end

    describe "with filters that name a path or look at the value" do
      around do |example|
        saved = Railwatch.config.redact_params
        filters = Rails.application.config.filter_parameters
        pin = ->(key, value) { value.replace("[PIN]") if key == "pin" && value.is_a?(String) && value.match?(/\A\d{4}\z/) }
        Railwatch.config.redact_params = saved + [ "billing.number" ]
        filters << pin
        Railwatch.instance_variable_set(:@redactor, nil)
        example.run
      ensure
        Railwatch.config.redact_params = saved
        filters.delete(pin)
        Railwatch.instance_variable_set(:@redactor, nil)
      end

      it "masks a key a dotted filter names through its parents, and only there" do
        scrubbed = Railwatch.redactor.scrub(billing: { number: "4111111111111111", city: "Paris" }, shipping: { number: "12" })

        expect(scrubbed).to eq(billing: { number: "[FILTERED]", city: "Paris" }, shipping: { number: "12" })
      end

      it "gives a Proc filter the value itself, on a copy" do
        pin = +"1234"

        scrubbed = Railwatch.redactor.scrub(pin: pin, card: { pin: [ "5678" ] }, name: "Ada")

        expect(scrubbed).to eq(pin: "[PIN]", card: { pin: [ "[PIN]" ] }, name: "Ada")
        expect(pin).to eq("1234")
      end
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
