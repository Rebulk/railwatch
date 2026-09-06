# frozen_string_literal: true

require "spec_helper"

RSpec.describe "attachment record" do
  def raised_error
    raise "invoice render failed"
  rescue RuntimeError => e
    e
  end

  it "carries name, content_type, bytes, gzipped data, and exception_group_hash" do
    error = raised_error
    Nightrail.report(error, handled: true)

    Nightrail.attach("payload.json", '{"order":1,"total":"9.99"}', exception: error)

    att = nightrail_records(:attachment).sole
    expect(att[:v]).to eq(1)
    expect(att[:t]).to eq("attachment")
    expect(att[:_group]).to eq(Nightrail::Record.group_hash("payload.json"))
    expect(att[:name]).to eq("payload.json")
    expect(att[:content_type]).to eq("application/json")
    expect(att[:bytes]).to eq(26)
    expect(Zlib.gunzip(Base64.strict_decode64(att[:data]))).to eq('{"order":1,"total":"9.99"}')
    expect(att[:exception_group_hash]).to eq(nightrail_records(:exception).sole[:_group])
    expect(att[:timestamp]).to be_a(Float)
    expect(att[:deploy]).to eq("abc123")
  end

  it "reports bytes as the stored (post-truncation) size, not the original" do
    previous = Nightrail.config.max_attachment_bytes
    Nightrail.config.max_attachment_bytes = 16
    Nightrail.attach("dump.bin", "a" * 100)

    att = nightrail_records(:attachment).sole
    expect(att[:bytes]).to eq(16)
    expect(att[:truncated]).to be(true)
  ensure
    Nightrail.config.max_attachment_bytes = previous
  end
end
