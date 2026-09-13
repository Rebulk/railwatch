# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exception fingerprinting" do
  subject(:exceptions) { Railwatch::Subscribers::Exceptions }

  # The resolver lives on the shared config for the whole process; calling
  # Railwatch.fingerprint with no block clears it again.
  after { Railwatch.fingerprint }

  # The message part of the default fingerprint: what survives the class's
  # prefix rule and normalization.
  def message_part(error)
    exceptions.default_fingerprint(error, {}).last
  end

  def report(error, **options)
    Railwatch.report(error, handled: true, **options)
    railwatch_records(:exception).last
  end

  def raised(message)
    raise message
  rescue RuntimeError => e
    e
  end

  describe "normalize_message" do
    def normalize(message) = exceptions.normalize_message(message)

    it "collapses a SQL bind list so an IN (...) of any length groups together" do
      expect(normalize("no such table: logs_fts: ... WHERE id IN (?,?)")).to eq(normalize("no such table: logs_fts: ... WHERE id IN (?, ?, ?, ?)"))
      expect(normalize("WHERE id IN (1, 2, 3)")).to eq("WHERE id IN (?)")
    end

    it "replaces a UUID" do
      expect(normalize("order 3f1b6c1e-6b6e-4f2a-9c3d-2b7a1f0e5d44 missing")).to eq("order ? missing")
    end

    it "replaces an email address" do
      expect(normalize("no account for ada@example.com")).to eq("no account for ?")
    end

    it "replaces a URL" do
      expect(normalize("POST https://api.example.com/v2/charges?id=9 failed")).to eq("POST ? failed")
    end

    it "replaces an IPv4 address" do
      expect(normalize("connection refused from 10.0.12.4")).to eq("connection refused from ?")
    end

    it "replaces an ISO timestamp" do
      expect(normalize("expired at 2026-09-03T11:22:33Z")).to eq("expired at ?")
    end

    it "replaces a single- or double-quoted string" do
      expect(normalize(%(missing 'order_id' in "payload"))).to eq("missing ? in ?")
    end

    it "replaces hex of six characters or more, with or without an 0x prefix" do
      expect(normalize("digest deadbeef01 at 0x00007f9c")).to eq("digest ? at ?")
    end

    it "leaves short hex-looking words alone" do
      expect(normalize("bad ace")).to eq("bad ace")
    end

    it "replaces plain integers" do
      expect(normalize("retry 3 of 5")).to eq("retry ? of ?")
    end

    it "collapses whitespace and caps the result at 200 characters" do
      expect(normalize("too\n  many   spaces")).to eq("too many spaces")
      expect(normalize("x" * 300).length).to eq(200)
    end
  end

  describe "per-class message prefixes" do
    it "keeps everything before the first colon for the classes whose message is all variable data" do
      expect(message_part(KeyError.new("key not found: :order_id"))).to eq("key not found")
      expect(message_part(ArgumentError.new('invalid value for Integer(): "nope"'))).to eq("invalid value for Integer()")
      expect(message_part(TypeError.new("no implicit conversion: Symbol into Integer"))).to eq("no implicit conversion")
      expect(message_part(ActiveRecord::RecordNotFound.new("Couldn't find all Widgets with 'id': (1, 2)")))
        .to eq("Couldn't find all Widgets with ?")
    end

    it "keeps everything before the first \"for \" for the NameError family, whose message ends in the receiver" do
      expect(message_part(NoMethodError.new("undefined method 'ship' for an instance of Widget")))
        .to eq("undefined method ?")
      expect(message_part(NameError.new("undefined local variable or method 'total' for main:Object")))
        .to eq("undefined local variable or method ?")
    end

    it "builds the RecordInvalid prefix from a real validation failure" do
      widget = Widget.new
      widget.errors.add(:name, "can't be blank")

      expect(message_part(ActiveRecord::RecordInvalid.new(widget))).to eq("Validation failed")
    end

    it "keeps the whole message for a class that is not in the map" do
      expect(message_part(RuntimeError.new("payment gateway: timeout"))).to eq("payment gateway: timeout")
    end
  end

  describe "the default fingerprint" do
    it "ships on the record as its four parts plus the source it came from" do
      record = report(raised("boom 42"))

      expect(record[:fingerprint]).to eq([ "RuntimeError", record[:file], record[:line].to_s, "boom ?" ])
      expect(record[:fingerprint_source]).to eq("default")
      expect(record[:_group]).to eq(Railwatch::Record.group_hash(*record[:fingerprint]))
    end

    it "groups two occurrences that differ only in their variable data" do
      first = report(raised("charge 1a2b3c4d5e for ada@example.com failed after 3 attempts"))
      second = report(raised("charge 9f8e7d6c5b for zoe@example.com failed after 9 attempts"))

      expect(first[:message]).not_to eq(second[:message])
      expect(first[:_group]).to eq(second[:_group])
    end
  end

  describe "precedence" do
    it "prefers an explicit fingerprint: over everything else" do
      Railwatch.fingerprint { |_error, _default| [ "from-resolver" ] }
      error = raised("boom")
      def error.railwatch_fingerprint = [ "from-error" ]

      record = report(error, fingerprint: [ "billing", "stripe" ])

      expect(record[:fingerprint]).to eq([ "billing", "stripe" ])
      expect(record[:fingerprint_source]).to eq("report")
    end

    it "prefers the error's own #railwatch_fingerprint over the resolver" do
      Railwatch.fingerprint { |_error, _default| [ "from-resolver" ] }
      error = raised("boom")
      def error.railwatch_fingerprint = [ "payment", "adyen" ]

      record = report(error)

      expect(record[:fingerprint]).to eq([ "payment", "adyen" ])
      expect(record[:fingerprint_source]).to eq("error")
    end

    it "uses the resolver when the error has no fingerprint of its own" do
      Railwatch.fingerprint { |error, _default| [ "class", error.class.name ] }

      record = report(raised("boom"))

      expect(record[:fingerprint]).to eq([ "class", "RuntimeError" ])
      expect(record[:fingerprint_source]).to eq("resolver")
    end

    it "falls back to the default when the resolver returns nil or an empty array" do
      Railwatch.fingerprint { |_error, _default| nil }
      expect(report(raised("boom"))[:fingerprint_source]).to eq("default")

      Railwatch.fingerprint { |_error, _default| [] }
      expect(report(raised("boom"))[:fingerprint_source]).to eq("default")
    end

    it "falls back to the default when the resolver raises" do
      Railwatch.fingerprint { |_error, _default| raise "resolver is broken" }

      record = report(raised("boom 42"))

      expect(record[:fingerprint_source]).to eq("default")
      expect(record[:fingerprint].last).to eq("boom ?")
    end
  end

  describe "the :default splice" do
    it "expands to the parts Railwatch would have hashed, in place" do
      Railwatch.fingerprint { |_error, _default| [ "tenant-7", :default ] }

      record = report(raised("boom 42"))

      expect(record[:fingerprint]).to eq([ "tenant-7", "RuntimeError", record[:file], record[:line].to_s, "boom ?" ])
      expect(record[:fingerprint_source]).to eq("resolver")
    end

    it "gives two errors that would group apart the same group once spliced under a shared key" do
      Railwatch.fingerprint { |_error, _default| [ "checkout" ] }

      expect(report(raised("one"))[:_group]).to eq(report(raised("two"))[:_group])
    end
  end

  describe "part limits" do
    it "stringifies parts, drops the empty ones, and caps at 10 parts of 200 characters" do
      Railwatch.fingerprint { |_error, _default| [ :billing, 42, nil, "", "x" * 300, *Array.new(20, "pad") ] }

      parts = report(raised("boom"))[:fingerprint]
      expect(parts.size).to eq(10)
      expect(parts.first(3)).to eq([ "billing", "42", "x" * 200 ])
    end
  end

  describe "attachments" do
    it "files an attachment against the issue the custom fingerprint chose" do
      Railwatch.fingerprint { |_error, _default| [ "payments", "gateway-timeout" ] }
      error = raised("boom")

      record = report(error)
      Railwatch.attach("payload.json", '{"order":1}', exception: error)

      expect(railwatch_records(:attachment).last[:exception_group_hash]).to eq(record[:_group])
    end

    it "files an attachment against the issue an explicit Railwatch.report fingerprint chose" do
      error = raised("boom")
      record = report(error, fingerprint: [ "billing", "stripe" ])

      Railwatch.attach("payload.json", "{}", exception: error)

      expect(railwatch_records(:attachment).last[:exception_group_hash]).to eq(record[:_group])
    end
  end
end
