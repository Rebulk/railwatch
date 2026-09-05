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
end
