# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern do
  describe Lantern::SqlNormalizer do
    it "collapses literals, binds, and IN lists so identical shapes group together" do
      a = described_class.normalize("SELECT * FROM users WHERE id = 1 AND name = 'a' AND x IN (1, 2, 3)")
      b = described_class.normalize("SELECT * FROM users WHERE id = 42 AND name = 'zz' AND x IN (9)")
      expect(a).to eq(b)
      expect(a).to eq("SELECT * FROM users WHERE id = ? AND name = ? AND x IN (?)")
    end

    it "treats $1 binds as placeholders on Postgres" do
      expect(described_class.normalize("SELECT 1 WHERE a = $1", adapter: "postgresql")).to eq("SELECT ? WHERE a = ?")
    end

    it "removes comments without exposing literals around comment-like text" do
      sql = "SELECT '-- not a comment', secret FROM users /* token=very-secret */ WHERE email = 'person@example.test' -- password=hunter2"
      normalized = described_class.normalize(sql)
      expect(normalized).to eq("SELECT ?, secret FROM users WHERE email = ?")
      expect(normalized).not_to include("very-secret", "person@example.test", "hunter2")
    end

    it "fully removes nested comments and preserves comment markers in quoted identifiers" do
      sql = 'SELECT "odd--column" FROM "users/*archive*/" /* outer /* password=nested-secret */ token=outer-secret */ WHERE id = 1'
      normalized = described_class.normalize(sql, adapter: "postgresql")
      expect(normalized).to eq('SELECT "odd--column" FROM "users/*archive*/" WHERE id = ?')
      expect(normalized).not_to include("nested-secret", "outer-secret")
    end

    it "removes MySQL hash comments" do
      normalized = described_class.normalize("SELECT `odd#column` FROM users # api_key=private\nWHERE id=2", adapter: "mysql2")
      expect(normalized).to eq("SELECT `odd#column` FROM users WHERE id=?")
      expect(normalized).not_to include("private")
    end

    it "hides Postgres dollar quotes, escape strings, scientific numbers, and hex values" do
      sql = <<~SQL
        SELECT $$private$$, $tag$also-private$tag$, E'it\\'s private', 6.02e23, 0xdeadbeef
      SQL
      expect(described_class.normalize(sql, adapter: "postgresql"))
        .to eq("SELECT ?, ?, ?, ?, ?")
    end

    it "hides PostgreSQL dollar quotes with non-ASCII identifier tags" do
      sql = "SELECT $é$customer-secret@example.test$é$, $aπ$token=prod-deadbeef$aπ$"

      normalized = described_class.normalize(sql, adapter: "postgresql")

      expect(normalized).to eq("SELECT ?, ?")
      expect(normalized).not_to include("customer-secret@example.test", "prod-deadbeef")
    end

    it "masks values inside PostgreSQL arrays and subscripts instead of treating brackets as identifiers" do
      expect(described_class.normalize("SELECT ARRAY['customer-secret@example.test', 987654321]", adapter: "postgresql"))
        .to eq("SELECT ARRAY[?, ?]")
      expect(described_class.normalize("SELECT tags[987654321] FROM users", adapter: "postgresql"))
        .to eq("SELECT tags[?] FROM users")

      commented = described_class.normalize("SELECT ARRAY[1 /* token=comment-secret */, 2]", adapter: "postgresql")
      expect(commented).to eq("SELECT ARRAY[? , ?]")
      expect(commented).not_to include("comment-secret")

      quoted = "SELECT ARRAY[E'it\\'s escape-secret', $tag$dollar-secret$tag$]"
      expect(described_class.normalize(quoted, adapter: "postgresql"))
        .to eq("SELECT ARRAY[?, ?]")
    end

    it "preserves bracket-quoted identifiers only for SQLite" do
      sql = "SELECT [odd]]column] FROM [users]"
      expect(described_class.normalize(sql, adapter: "sqlite")).to eq(sql)
    end

    it "normalizes leading and trailing decimal points" do
      expect(described_class.normalize("SELECT .5, 1., -2.0"))
        .to eq("SELECT ?, ?, ?")
    end

    it "fails closed for unterminated quoted values in rejected SQL" do
      expect(described_class.normalize("SELECT 'private-to-end", adapter: "sqlite"))
        .to eq("SELECT ?")
      expect(described_class.normalize('SELECT "private-to-end', adapter: "mysql2"))
        .to eq("SELECT ?")
      expect(described_class.normalize("SELECT $tag$private-to-end", adapter: "postgresql"))
        .to eq("SELECT ?")
      expect(described_class.normalize('SELECT "private-identifier-to-end', adapter: "postgresql"))
        .to eq("SELECT ?")
      expect(described_class.normalize("SELECT `private-identifier-to-end", adapter: "mysql2"))
        .to eq("SELECT ?")
    end

    it "hides MySQL and Trilogy double-quoted and backslash-escaped string values" do
      sql = 'SELECT "private", \'it\\\'s private\' FROM users WHERE id = 7'
      expect(described_class.normalize(sql, adapter: "trilogy"))
        .to eq("SELECT ?, ? FROM users WHERE id = ?")
    end

    it "preserves unambiguous SQLite double-quoted identifiers while hiding ambiguous strings and blobs" do
      sql = %(SELECT "users"."email", "private@example.test" FROM "users" WHERE payload = X'736563726574')
      expect(described_class.normalize(sql, adapter: "sqlite"))
        .to eq('SELECT "users"."email", ? FROM "users" WHERE payload = ?')
    end

    it "scans each dialect's default backslash rule rather than abandoning the statement" do
      slash = "\\"
      # SQLite and PostgreSQL have no backslash escapes by default, so the
      # quote after the backslash closes the string and the next literal is
      # its own value.
      trailing = "SELECT 'ends#{slash}','private-after@example.test'"
      expect(described_class.normalize(trailing, adapter: "sqlite")).to eq("SELECT ?,?")
      expect(described_class.normalize(trailing, adapter: "postgresql")).to eq("SELECT ?,?")

      # MySQL's default is the opposite, and it is the quoting Active Record
      # emits, so the escaped quote must not end the value.
      mysql = "SELECT 'it#{slash}'s private'"
      expect(described_class.normalize(mysql, adapter: "mysql2")).to eq("SELECT ?")
      expect(described_class.normalize(mysql, adapter: "trilogy")).to eq("SELECT ?")
    end

    it "keeps statements that differ only after a backslash-escaped quote in different groups" do
      slash = "\\"
      by_id = "SELECT * FROM users WHERE name = 'O#{slash}'Brien' AND id = 1"
      by_state = "SELECT * FROM users WHERE name = 'O#{slash}'Brien' AND state = 'x'"

      expect(described_class.normalize(by_id, adapter: "mysql2"))
        .to eq("SELECT * FROM users WHERE name = ? AND id = ?")
      expect(described_class.normalize(by_state, adapter: "mysql2"))
        .to eq("SELECT * FROM users WHERE name = ? AND state = ?")
      expect(described_class.group(by_id, adapter: "mysql2"))
        .not_to eq(described_class.group(by_state, adapter: "mysql2"))
    end

    it "honors escape strings for PostgreSQL-compatible aliases and absent adapter metadata" do
      sql = "SELECT E'it\\'s customer-secret@example.test', 42"

      [ "PostGIS", "CockroachDB", nil ].each do |adapter|
        normalized = described_class.normalize(sql, adapter: adapter)
        expect(normalized).to eq("SELECT ?, ?")
        expect(normalized).not_to include("customer-secret@example.test")
      end
    end

    it "treats an unknown adapter as backslash-escaping, which masks more rather than less" do
      slash = "\\"
      sql = "SELECT 'it#{slash}'s customer-secret@example.test', 42"

      [ nil, "", "AcmeDB" ].each do |adapter|
        normalized = described_class.normalize(sql, adapter: adapter)
        expect(normalized).to eq("SELECT ?, ?")
        expect(normalized).not_to include("customer-secret@example.test")
      end
    end

    it "fails closed for MySQL-style values and comments when adapter metadata is unknown" do
      [ nil, "", "AcmeDB" ].each do |adapter|
        double_quoted = described_class.normalize(
          'SELECT "private-dqs@example.test", 42', adapter: adapter
        )
        hash_commented = described_class.normalize(
          "SELECT 1 # token=private-hash-secret\n, 2", adapter: adapter
        )

        expect(double_quoted).to eq("SELECT ?, ?")
        expect(double_quoted).not_to include("private-dqs@example.test")
        expect(hash_commented).to eq("SELECT ? , ?")
        expect(hash_commented).not_to include("private-hash-secret")
      end

      postgres = described_class.normalize(
        'SELECT "users"."email" # \'private-operator-value\' FROM "users"', adapter: "postgresql"
      )
      expect(postgres).to eq('SELECT "users"."email" # ? FROM "users"')
    end

    it "masks underscored and base-prefixed numeric literals" do
      sql = "SELECT 123_456_789, 0xDEAD_BEEF, 0b0110_0001, 0o123_456"
      expect(described_class.normalize(sql, adapter: "sqlite")).to eq("SELECT ?, ?, ?, ?")
    end

    it "preserves numbered placeholders as one placeholder" do
      expect(described_class.normalize("SELECT * FROM users WHERE id = ?123", adapter: "sqlite"))
        .to eq("SELECT * FROM users WHERE id = ?")
    end

    it "scrubs malformed encodings instead of raising" do
      invalid = ("SELECT ".b + "\xFFprivate".b).force_encoding(Encoding::UTF_8)
      utf16 = "SELECT 'private'".encode(Encoding::UTF_16LE)

      expect { described_class.normalize(invalid, adapter: "sqlite") }.not_to raise_error
      expect(described_class.normalize(invalid, adapter: "sqlite")).to be_valid_encoding
      expect(described_class.normalize(utf16, adapter: "sqlite")).to eq("SELECT ?")
    end

    it "bounds and marks huge SQL while remaining fast for non-ASCII input" do
      sql = "SELECT /* #{'é' * (described_class::MAX_NORMALIZE_BYTES * 2)} private-at-end */ 1"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      normalized = described_class.normalize(sql, adapter: "postgresql")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(normalized).to end_with(described_class::TRUNCATED)
      expect(normalized).not_to include("private-at-end")
      expect(elapsed).to be < 1.0

      described_class.group_and_normalized(sql, adapter: "postgresql", connection_name: "huge")
      adapter_cache = described_class.instance_variable_get(:@cache).fetch("postgresql", {})
      expect(adapter_cache).not_to have_key("huge")
    end

    it "returns the same group hash for a repeated exact SQL string, served from cache" do
      a = described_class.group("SELECT * FROM users WHERE id = 1", connection_name: "primary")
      b = described_class.group("SELECT * FROM users WHERE id = 1", connection_name: "primary")
      expect(a).to eq(b)
    end

    it "returns the cached normalized SQL alongside the group hash" do
      group, normalized = described_class.group_and_normalized("SELECT * FROM users WHERE id = 1")
      expect(group).to eq(described_class.group("SELECT * FROM users WHERE id = 1"))
      expect(normalized).to eq("SELECT * FROM users WHERE id = ?")
    end

    it "deep-freezes cached values so callers cannot corrupt later cache hits" do
      sql = "SELECT * FROM users WHERE id = 918273645"
      first = described_class.group_and_normalized(sql, adapter: "postgresql", connection_name: "mutation-test")

      expect(first).to be_frozen
      expect(first[0]).to be_frozen
      expect(first[1]).to be_frozen
      expect { first[0] << " corrupted" }.to raise_error(FrozenError)
      expect { first[1] << " corrupted" }.to raise_error(FrozenError)

      cached = described_class.group_and_normalized(sql, adapter: "postgresql", connection_name: "mutation-test")
      expect(cached).to equal(first)
      expect(cached[0]).to eq(Lantern::Record.group_hash("mutation-test", cached[1]))
    end

    it "does not share adapter-sensitive normalized SQL across adapter caches" do
      sql = 'SELECT "private@example.test"'
      pg = described_class.group_and_normalized(sql, adapter: "postgresql", connection_name: "primary")[1]
      mysql = described_class.group_and_normalized(sql, adapter: "mysql2", connection_name: "primary")[1]

      expect(pg).to eq(sql)
      expect(mysql).to eq("SELECT ?")
    end

    it "bounds its cache instead of growing without limit" do
      bucket = described_class.instance_variable_get(:@cache)[""]["primary"]
      (described_class::CACHE_LIMIT + 5).times { |i| described_class.group("SELECT #{i}", connection_name: "primary") }
      expect(bucket.size).to be <= described_class::CACHE_LIMIT
    end
  end

  describe Lantern::Buffer do
    it "drops the oldest record and counts it when over capacity" do
      buffer = described_class.new(2)
      buffer.push(1); buffer.push(2); buffer.push(3)
      batch, dropped = buffer.drain
      expect(batch).to eq([ 2, 3 ])
      expect(dropped).to eq(1)
      expect(buffer.size).to eq(0)
    end
  end

  describe Lantern::Redactor do
    it "masks configured headers and app filter_parameters" do
      r = described_class.new(Lantern.config)
      expect(r.headers("Authorization" => "x", "Host" => "h")).to eq("Authorization" => "[FILTERED]", "Host" => "h")
      expect(r.params("password" => "x", "name" => "n")).to eq("password" => "[FILTERED]", "name" => "n")
    end
  end

  describe Lantern::Execution do
    it "accumulates stage durations in microseconds" do
      exe = described_class.new(source: :request, sampled: true)
      exe.enter_stage(:a)
      sleep 0.002
      exe.enter_stage(:b)
      exe.finish_stages
      expect(exe.stage_durations[:a]).to be >= 2_000
      expect(exe.stage_durations).to have_key(:b)
    end
  end

  describe "before_ingest" do
    it "drops a batch when a hook returns false" do
      Lantern.before_ingest { |_batch| false }
      Lantern.record(:log, level: "info", message: "x", tags: [], context: "{}")
      expect(lantern_records).to be_empty
    ensure
      Lantern.config.before_ingest.clear
    end
  end

  describe "transport" do
    it "posts gzip NDJSON with the bearer token and reports drops" do
      transport = Lantern::Transport::Http.new(Lantern.config)
      result = transport.deliver([ { t: "log" } ], dropped: 3)
      expect(result.ok).to be true
      expect(WebMock).to have_requested(:post, "http://lantern.test/ingest")
        .with(headers: { "Authorization" => "Bearer test-token", "Content-Encoding" => "gzip", "X-Lantern-Dropped" => "3" })
    end

    it "never raises when the platform is down" do
      stub_request(:post, "http://lantern.test/ingest").to_timeout
      result = Lantern::Transport::Http.new(Lantern.config).deliver([ { t: "log" } ])
      expect(result.ok).to be false
    end
  end

  describe "commands" do
    it "records a rake task as a command execution" do
      require "rake"
      Rake::Task.define_task(:lantern_demo) { Widget.count }
      Rake::Task[:lantern_demo].execute
      cmd = lantern_records(:command).sole
      expect(cmd).to include(name: "lantern_demo", exit_code: 0)
      expect(cmd[:counters][:queries]).to eq(1)
    end
  end

  describe "job failures" do
    it "records a failed attempt and an unhandled exception in the job's execution" do
      WidgetJob.perform_later("x", fail: true)
      expect { perform_enqueued_jobs }.to raise_error(RuntimeError)
      attempt = lantern_records(:job_attempt).sole
      ex = lantern_records(:exception).sole
      expect(attempt[:status]).to eq("failed")
      expect(ex[:execution_id]).to eq(attempt[:execution_id])
      expect(ex[:execution_source]).to eq("job")
    end
  end

  describe "job attempts" do
    it "reports released, not failed, when retry_on catches the error and re-enqueues" do
      FlakyJob.perform_later
      perform_enqueued_jobs
      attempt = lantern_records(:job_attempt).sole
      expect(attempt[:status]).to eq("released")
      expect(lantern_records(:exception)).to be_empty
    end

    it "measures queue_latency at perform-start, not after the job runs" do
      SlowJob.perform_later
      perform_enqueued_jobs
      attempt = lantern_records(:job_attempt).sole
      # queue_latency is the enqueue -> perform-start gap; duration is the
      # perform itself (a 50ms sleep). If queue_latency were measured after
      # the job ran instead of at perform-start, it would include the sleep
      # and be roughly equal to (or larger than) duration.
      expect(attempt[:queue_latency]).to be < attempt[:duration]
      expect(attempt[:duration]).to be >= 50_000
    end

    it "reports the adapter as connection and includes the job's concurrency_key" do
      ConcurrentJob.perform_later
      perform_enqueued_jobs
      attempt = lantern_records(:job_attempt).sole
      expect(attempt[:connection]).to eq("Test")
      expect(attempt[:concurrency_key]).to eq("ConcurrentJob/widget")
    end

    it "gives a pruned job attempt a fresh execution_id and trace_id" do
      ActiveSupport::Notifications.instrument("fail_many_claimed.solid_queue", job_ids: [ 123 ], error: "worker died")
      attempt = lantern_records(:job_attempt).sole
      expect(attempt[:provider_job_id]).to eq("123")
      expect(attempt[:status]).to eq("failed")
      expect(attempt[:execution_id]).to be_a(String)
      expect(attempt[:trace_id]).to be_a(String)
    end
  end

  describe "process info" do
    it "reports boot_seconds measured from Lantern::BOOTED_AT, not an unset global" do
      Lantern::Subscribers::ProcessInfo.install!(Rails.application)
      Lantern::Subscribers::ProcessInfo.record!
      proc_record = lantern_records(:process).sole
      expect(proc_record[:boot_seconds]).to be_between(0, 60)
    end
  end

  describe "bin/rails runner instrumentation" do
    it "records a command execution for a runner invocation" do
      fake = Class.new do
        prepend Lantern::Patches::RunnerCommand
        def perform(code_or_file = nil, *)
          code_or_file
        end
      end
      fake.new.perform("Widget.count")
      cmd = lantern_records(:command).sole
      expect(cmd).to include(name: "runner", class: "Rails::Command::RunnerCommand", exit_code: 0)
      expect(cmd[:command]).to eq("rails runner Widget.count")
    end
  end

  describe "exception code and sql_state" do
    it "captures the errno for a SystemCallError" do
      Lantern.report(Errno::ECONNREFUSED.new("refused"), handled: true)
      ex = lantern_records(:exception).sole
      expect(ex[:code]).to eq(Errno::ECONNREFUSED::Errno)
    end
  end

  describe "transactions" do
    it "reports statement_count for the writes made inside a transaction" do
      require "rake"
      Rake::Task.define_task(:lantern_txn_demo) do
        ActiveRecord::Base.transaction do
          Widget.create!(name: "t1")
          Widget.create!(name: "t2")
          Widget.create!(name: "t3")
        end
      end
      Rake::Task[:lantern_txn_demo].execute
      txn = lantern_records(:transaction).sole
      expect(txn[:outcome]).to eq("commit")
      expect(txn[:statement_count]).to eq(3)
      expect(txn[:_group]).to be_a(String)
    end
  end

  describe "default vendor command exclusion" do
    it "emits no command record for a default vendor rake task unless opted in" do
      require "rake"
      Rake::Task.define_task(:"db:migrate") { Widget.count }
      Rake::Task[:"db:migrate"].execute
      expect(lantern_records(:command)).to be_empty

      Lantern.config.capture_default_vendor_commands = true
      Rake::Task[:"db:migrate"].execute
      expect(lantern_records(:command).sole[:name]).to eq("db:migrate")
    ensure
      Lantern.config.capture_default_vendor_commands = false
    end
  end

  describe "self-monitoring" do
    it "reports a bad token once, not on every flush after it" do
      stub_request(:post, "http://lantern.test/ingest").to_return(status: 401, body: "unauthorized")
      errors = []
      Lantern.on_unrecoverable { |e| errors << e }
      reporter = Lantern::Reporter.new(Lantern.config)

      3.times do
        reporter.buffer.push({ t: "log" })
        reporter.flush
      end

      expect(errors.size).to eq(1)
      expect(errors.first.status).to eq(401)
      expect(a_request(:post, "http://lantern.test/ingest")).to have_been_made.once
    ensure
      Lantern.config.on_unrecoverable = nil
    end

    it "calls on_unrecoverable when ingest permanently rejects a batch" do
      stub_request(:post, "http://lantern.test/ingest").to_return(status: 422, body: "boom")
      errors = []
      Lantern.on_unrecoverable { |e| errors << e }
      reporter = Lantern::Reporter.new(Lantern.config)
      reporter.buffer.push({ t: "log" })

      reporter.flush

      expect(errors.one?).to be(true)
      expect(errors.first).to be_a(Lantern::Reporter::DeliveryError)
      expect(errors.first.status).to eq(422)
      expect(errors.first.message).to include("boom")
    ensure
      Lantern.config.on_unrecoverable = nil
    end
  end

  describe Lantern::Faraday do
    it "records an outgoing_request for a Faraday connection using the middleware" do
      require "rake"
      stub_request(:get, "https://api.example.test/things").to_return(status: 204)
      conn = ::Faraday.new("https://api.example.test") { |f| f.use Lantern::Faraday }
      Rake::Task.define_task(:lantern_faraday_demo) { conn.get("/things") }
      Rake::Task[:lantern_faraday_demo].execute
      out = lantern_records(:outgoing_request).sole
      expect(out).to include(host: "api.example.test", method: "GET", url: "https://api.example.test/things", status_code: 204)
      expect(out[:duration]).to be >= 0
    end

    it "records the error and re-raises when the connection fails" do
      require "rake"
      stub_request(:get, "https://api.example.test/things").to_raise(Faraday::ConnectionFailed.new("down"))
      conn = ::Faraday.new("https://api.example.test") { |f| f.use Lantern::Faraday }
      Rake::Task.define_task(:lantern_faraday_error_demo) { conn.get("/things") }
      expect { Rake::Task[:lantern_faraday_error_demo].execute }.to raise_error(Faraday::ConnectionFailed)
      out = lantern_records(:outgoing_request).sole
      expect(out[:error]).to include("down")
    end
  end

  describe "Lantern.instrument_outgoing" do
    it "records an outgoing_request and returns the block's value" do
      require "rake"
      result = nil
      Rake::Task.define_task(:lantern_outgoing_demo) do
        result = Lantern.instrument_outgoing(:get, "https://api.example.test/things") { Struct.new(:status).new(204) }
      end
      Rake::Task[:lantern_outgoing_demo].execute
      expect(result.status).to eq(204)
      out = lantern_records(:outgoing_request).sole
      expect(out).to include(host: "api.example.test", method: "GET", status_code: 204)
    end
  end
end
