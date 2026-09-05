# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::UploadedFiles do
  def upload(file, type: "text/plain")
    ActionDispatch::Http::UploadedFile.new(
      tempfile: file, filename: File.basename(file.path), type: type, headers: ""
    )
  end

  it "preserves depth-first field order through nested hashes and arrays" do
    files = 3.times.map { |index| Tempfile.new([ "upload-#{index}", ".txt" ]) }
    files.each_with_index { |file, index| file.write("file #{index}"); file.rewind }
    params = { attachments: [ upload(files[0]), upload(files[1]) ], profile: { avatar: upload(files[2]) } }

    extracted = described_class.extract(params)

    expect(extracted.map { |entry| entry[:name] }).to eq(%w[attachments attachments avatar])
    expect(extracted.map { |entry| entry[:size] }).to eq([ 6, 6, 6 ])
  ensure
    files&.each(&:close!)
  end

  it "terminates safely for cyclic and deeply nested parameter trees" do
    cycle = []
    cycle << cycle
    deep = nil
    5_000.times { deep = { next: deep } }

    expect(described_class.extract(cycle)).to eq([])
    expect(described_class.extract(deep)).to eq([])
  end

  it "bounds the number of nodes inspected" do
    yielded = 0
    values = Class.new(Array) do
      define_method(:each) do |&block|
        super() do |value|
          yielded += 1
          block.call(value)
        end
      end
    end.new(Array.new(described_class::MAX_NODES + 100))

    expect(described_class.extract(values)).to eq([])
    expect(yielded).to be <= described_class::MAX_NODES
  end

  it "caps the number of uploaded files returned" do
    file = Tempfile.new([ "many-uploads", ".txt" ])
    params = Array.new(described_class::MAX_FILES + 10) { upload(file) }

    expect(described_class.extract(params).length).to eq(described_class::MAX_FILES)
  ensure
    file&.close!
  end

  it "recognizes Rack-native cached upload hashes" do
    file = Tempfile.new([ "rack-upload", ".txt" ])
    file.write("hello")
    file.rewind
    params = {
      "attachment" => { filename: "a.txt", type: "text/plain", name: "attachment", tempfile: file }
    }

    expect(described_class.extract(params).sole).to include(
      name: "attachment", size: 5, content_type: "text/plain"
    )
  ensure
    file&.close!
  end

  it "bounds and normalizes emitted strings and sizes" do
    io = StringIO.new("hello")
    invalid_type = ("text/" + "\xFF".b + ("x" * described_class::MAX_CONTENT_TYPE_BYTES)).b
    oversized_name = "a" * (described_class::MAX_NAME_BYTES + 100)
    params = {
      oversized_name => { filename: "a.txt", type: invalid_type, tempfile: io }
    }

    metadata = described_class.extract(params).sole

    expect(metadata[:name].bytesize).to eq(described_class::MAX_NAME_BYTES)
    expect(metadata[:content_type].bytesize).to be <= described_class::MAX_CONTENT_TYPE_BYTES
    expect(metadata[:content_type]).to be_valid_encoding
    expect(metadata[:size]).to eq(5)
    expect { JSON.generate(metadata) }.not_to raise_error
  end

  it "rejects string lookalikes and validates hostile file sizes" do
    lookalike = { filename: "a.txt", tempfile: "not an IO", type: "text/plain" }
    expect(described_class.extract(lookalike)).to eq([])

    io = Object.new
    io.define_singleton_method(:read) { }
    io.define_singleton_method(:rewind) { }
    io.define_singleton_method(:size) { -1 }
    invalid_size = { filename: "a.txt", tempfile: io, type: "text/plain" }
    expect(described_class.extract(invalid_size).sole[:size]).to be_nil

    io.define_singleton_method(:size) { 2**100 }
    expect(described_class.extract(invalid_size).sole[:size]).to eq(described_class::MAX_FILE_BYTES)

    io.define_singleton_method(:size) { "5" }
    expect(described_class.extract(invalid_size).sole[:size]).to be_nil
  end

  it "normalizes cached metadata without trusting its shape or encoding" do
    cycle = []
    cycle << cycle
    expect(described_class.normalize(cycle)).to eq([])

    invalid = "\xFF".b
    rows = Array.new(described_class::MAX_FILES + 1) do
      { "name" => invalid, "size" => -1, "content_type" => invalid, "error" => invalid }
    end
    normalized = described_class.normalize(rows)

    expect(normalized.size).to eq(described_class::MAX_FILES)
    expect(normalized.first[:size]).to be_nil
    expect(normalized.first.values_at(:name, :content_type, :error)).to all(be_valid_encoding)
    expect { JSON.generate(normalized) }.not_to raise_error
  end

  it "does not coerce arbitrary upload metadata to strings" do
    coerced = false
    hostile = Object.new
    hostile.define_singleton_method(:nil?) do
      coerced = true
      raise "nil? must not run"
    end
    hostile.define_singleton_method(:is_a?) do
      coerced = true
      raise "is_a? must not run"
    end
    hostile.define_singleton_method(:to_s) do
      coerced = true
      "x" * (32 * 1024 * 1024)
    end

    normalized = described_class.normalize([ { name: hostile, content_type: hostile, error: hostile } ])
    params = { hostile => { filename: "a.txt", tempfile: StringIO.new("x"), type: hostile } }
    extracted = described_class.extract(params)

    expect(coerced).to be(false)
    expect(normalized.sole.values_at(:name, :content_type, :error)).to eq([ nil, nil, nil ])
    expect(extracted.sole).to include(name: nil, content_type: nil, size: 1)
  end

  it "uses core traversal methods for hostile container subclasses" do
    called = []
    hostile = silence_warnings do
      klass = Class.new(Hash) do
        define_method(:object_id) { called << :object_id }
        define_method(:each) { called << :each }
      end
      klass.new
    end
    upload = { filename: "a.txt", tempfile: StringIO.new("x"), type: "text/plain" }
    Hash.instance_method(:[]=).bind_call(hostile, :attachment, upload)

    extracted = described_class.extract(hostile)

    expect(called).to be_empty
    expect(extracted.sole).to include(name: "attachment", size: 1, content_type: "text/plain")
  end
end
