# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Lantern::Attachments do
  def unpack(record)
    Zlib.gunzip(Base64.strict_decode64(record[:data]))
  end

  describe "Lantern.attach" do
    it "ships a v1 attachment record grouped by name, with the payload gzipped and base64-encoded" do
      Lantern.attach("payload.json", '{"order":1}')

      att = lantern_records(:attachment).sole
      expect(att[:v]).to eq(1)
      expect(att[:t]).to eq("attachment")
      expect(att[:_group]).to eq(Lantern::Record.group_hash("payload.json"))
      expect(att[:name]).to eq("payload.json")
      expect(att[:bytes]).to eq(11)
      expect(unpack(att)).to eq('{"order":1}')
      expect(att).not_to have_key(:truncated)
    end

    it "returns the record it wrote" do
      record = Lantern.attach("payload.json", "{}")

      expect(record).to eq(lantern_records(:attachment).sole)
    end

    it "reads an IO instead of storing its inspect output" do
      Lantern.attach("payload.json", StringIO.new('{"order":1}'))

      expect(unpack(lantern_records(:attachment).sole)).to eq('{"order":1}')
    end

    it "reads the file a Pathname points at" do
      file = Tempfile.new([ "lantern", ".json" ])
      file.write('{"from":"disk"}')
      file.close

      Lantern.attach("payload.json", Pathname.new(file.path))

      att = lantern_records(:attachment).sole
      expect(unpack(att)).to eq('{"from":"disk"}')
      expect(att[:bytes]).to eq(15)
    ensure
      file.unlink
    end

    it "records nothing when the file behind a Pathname is missing" do
      expect(Lantern.attach("payload.json", Pathname.new("/nonexistent/lantern.json"))).to be_nil
      expect(lantern_records(:attachment)).to be_empty
    end

    it "truncates the name to 255 characters and groups on the truncated name" do
      Lantern.attach("#{'x' * 300}.json", "{}")

      att = lantern_records(:attachment).sole
      expect(att[:name].length).to eq(255)
      expect(att[:_group]).to eq(Lantern::Record.group_hash("x" * 255))
    end
  end

  describe "content type" do
    it "detects the type from the name's extension" do
      Lantern.attach("payload.json", "{}")

      expect(lantern_records(:attachment).sole[:content_type]).to eq("application/json")
    end

    it "falls back to application/octet-stream for an unrecognised extension" do
      Lantern.attach("dump.zzz", "raw")

      expect(lantern_records(:attachment).sole[:content_type]).to eq("application/octet-stream")
    end

    it "prefers an explicitly passed content_type over the detected one" do
      Lantern.attach("payload.json", "id,name\n1,a", content_type: "text/csv")

      expect(lantern_records(:attachment).sole[:content_type]).to eq("text/csv")
    end

    it "truncates the content type to 128 characters" do
      Lantern.attach("payload.json", "{}", content_type: "text/#{'x' * 200}")

      expect(lantern_records(:attachment).sole[:content_type].length).to eq(128)
    end
  end

  describe "size cap" do
    around do |example|
      previous = Lantern.config.max_attachment_bytes
      Lantern.config.max_attachment_bytes = 10
      example.run
    ensure
      Lantern.config.max_attachment_bytes = previous
    end

    it "truncates a payload over max_attachment_bytes and flags it" do
      Lantern.attach("dump.bin", "0123456789abcdef")

      att = lantern_records(:attachment).sole
      expect(att[:bytes]).to eq(10)
      expect(att[:truncated]).to be(true)
      expect(unpack(att)).to eq("0123456789")
    end

    it "leaves a payload exactly at the cap alone" do
      Lantern.attach("dump.bin", "0123456789")

      att = lantern_records(:attachment).sole
      expect(att[:bytes]).to eq(10)
      expect(att).not_to have_key(:truncated)
    end

    it "caps on bytes, not characters" do
      Lantern.attach("dump.bin", "é" * 8) # 16 bytes

      att = lantern_records(:attachment).sole
      expect(att[:bytes]).to eq(10)
      expect(att[:truncated]).to be(true)
    end

    it "never asks an IO for more than the cap plus one byte" do
      reader = Class.new do
        attr_reader :requested

        def read(length = nil)
          raise "unbounded read" unless length

          @requested = length
          "0123456789abcdef".byteslice(0, length)
        end
      end.new

      Lantern.attach("dump.bin", reader)

      expect(reader.requested).to eq(11)
      expect(unpack(lantern_records(:attachment).sole)).to eq("0123456789")
    end
  end

  describe "linking to an exception" do
    def raised_error
      raise "attachment demo"
    rescue RuntimeError => e
      e
    end

    it "files the attachment under the same group hash the exception record ships with" do
      error = raised_error
      Lantern.report(error, handled: true)
      Lantern.attach("payload.json", '{"order":1}', exception: error)

      expect(lantern_records(:attachment).sole[:exception_group_hash])
        .to eq(lantern_records(:exception).sole[:_group])
    end

    it "leaves exception_group_hash nil when no exception was given" do
      Lantern.attach("payload.json", "{}")

      expect(lantern_records(:attachment).sole[:exception_group_hash]).to be_nil
    end

    # Raised inside Kernel#Integer, so no frame is under Rails.root and
    # group_for has to fall back to the top of the backtrace.
    def error_raised_outside_the_app
      Integer("nope")
    rescue ArgumentError => e
      e
    end

    it "still links an exception with no application frame" do
      error = error_raised_outside_the_app

      Lantern.attach("payload.json", "{}", exception: error)

      expect(lantern_records(:attachment).sole[:exception_group_hash])
        .to eq(Lantern::Subscribers::Exceptions.group_for(error))
    end
  end

  describe "Lantern.report(attachments:)" do
    def report_with_attachments
      raise "payload rejected"
    rescue RuntimeError => e
      Lantern.report(e, handled: true, attachments: { "payload.json" => '{"order":1}', "headers.txt" => "X-Sig: abc" })
    end

    it "captures the exception and one attachment per entry, all linked to it" do
      report_with_attachments

      exception = lantern_records(:exception).sole
      attachments = lantern_records(:attachment)
      expect(attachments.map { |a| a[:name] }).to eq([ "payload.json", "headers.txt" ])
      expect(attachments.map { |a| a[:exception_group_hash] }.uniq).to eq([ exception[:_group] ])
      expect(unpack(attachments.first)).to eq('{"order":1}')
    end

    it "returns the exception record, not the attachments" do
      expect(report_with_attachments[:t]).to eq("exception")
    end

    it "still reports the exception when no attachments are passed" do
      begin
        raise "plain"
      rescue RuntimeError => e
        Lantern.report(e, handled: true)
      end

      expect(lantern_records(:exception).size).to eq(1)
      expect(lantern_records(:attachment)).to be_empty
    end
  end

  describe "no-ops" do
    it "records nothing and returns nil when Lantern is disabled" do
      Lantern.config.enabled = false

      expect(Lantern.attach("payload.json", "{}")).to be_nil
      expect(lantern_records(:attachment)).to be_empty
    ensure
      Lantern.config.enabled = true
    end

    it "records nothing for an empty payload" do
      expect(Lantern.attach("payload.json", "")).to be_nil
      expect(lantern_records(:attachment)).to be_empty
    end

    it "records nothing for a nil payload" do
      expect(Lantern.attach("payload.json", nil)).to be_nil
      expect(lantern_records(:attachment)).to be_empty
    end
  end

  describe "envelope" do
    it "ships standalone, with no execution envelope, when nothing is executing" do
      Lantern.attach("payload.json", "{}")

      att = lantern_records(:attachment).sole
      expect(att).not_to have_key(:execution_id)
      expect(att).not_to have_key(:trace_id)
    end

    it "belongs to the execution it was made inside" do
      Lantern.start_execution(source: :command, sample_kind: :commands)
      Lantern.attach("payload.json", "{}")
      Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                               command: "rake demo", exit_code: 0)

      att = lantern_records(:attachment).sole
      command = lantern_records(:command).sole
      expect(att[:execution_id]).to eq(command[:execution_id])
      expect(att[:execution_source]).to eq("command")
    end

    it "is dropped, like every other child record, when the execution is sampled out" do
      exe = Lantern.start_execution(source: :command, sample_kind: :commands)
      exe.sampled = false
      Lantern.attach("payload.json", "{}")
      Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                               command: "rake demo", exit_code: 0)

      expect(lantern_records(:attachment)).to be_empty
    end
  end
end
