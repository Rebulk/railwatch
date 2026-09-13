# frozen_string_literal: true

require "spec_helper"
require "railwatch/source_maps"
require "tmpdir"

RSpec.describe Railwatch::SourceMaps do
  let(:document) { JSON.generate(version: 3, sources: [ "app/frontend/widget.tsx" ], names: [], mappings: "AAAA") }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      FileUtils.mkdir_p(File.join(directory, "vite/assets"))
      @file = File.join(directory, "vite/assets/widget.js.map")
      File.write(@file, document)
      example.run
    end
  end

  it "uploads the public-relative filename and only deletes after a matching acknowledgment" do
    stub = stub_request(:post, "http://railwatch.test/ingest/sourcemaps")
      .with(body: document, headers: { "X-Railwatch-Deploy" => "abc123", "X-Railwatch-Filename" => "vite/assets/widget.js", "Content-Type" => "application/octet-stream", "Authorization" => "Bearer test-token" })
      .to_return(status: 201, body: JSON.generate(ok: true, filename: "vite/assets/widget.js", bytes: document.bytesize))
    expect(described_class.new(Railwatch.config).upload(directory: @directory, delete: true)).to eq(1)
    expect(stub).to have_been_requested
    expect(File.exist?(@file)).to eq(false)
  end

  it "retains local maps by default" do
    stub_request(:post, "http://railwatch.test/ingest/sourcemaps")
      .to_return(status: 201, body: JSON.generate(ok: true, filename: "vite/assets/widget.js", bytes: document.bytesize))
    described_class.new(Railwatch.config).upload(directory: @directory)
    expect(File.exist?(@file)).to eq(true)
  end

  it "keeps files on upload failure or an invalid acknowledgment and does not follow redirects" do
    [ 302, 500, 200 ].each do |status|
      stub_request(:post, "http://railwatch.test/ingest/sourcemaps").to_return(status: status, body: "{}", headers: { "Location" => "https://other.test/" })
      expect { described_class.new(Railwatch.config).upload(directory: @directory, delete: true) }.to raise_error(RuntimeError)
      expect(File.exist?(@file)).to eq(true)
    end
  end

  it "refuses symlinks and oversized maps before sending their content" do
    File.symlink(@file, File.join(@directory, "linked.map"))
    expect { described_class.new(Railwatch.config).upload(directory: @directory) }.to raise_error(ArgumentError, /regular file/)
    File.delete(File.join(@directory, "linked.map"))
    stub_const("Railwatch::SourceMaps::MAX_BYTES", 10)
    expect { described_class.new(Railwatch.config).upload(directory: @directory) }.to raise_error(ArgumentError, /exceeds/)
  end

  it "retains browser columns needed to resolve minified stacks" do
    frames = Railwatch::Backtrace.js_frames("at render (https://app.test/vite/assets/widget.js:1:27)", origin: "https://app.test")
    expect(frames.first).to include(file: "vite/assets/widget.js", line: 1, column: 27)
  end
end
