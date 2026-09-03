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
end
