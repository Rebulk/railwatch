# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::RequestMediaType do
  it "matches multipart form data exactly, case-insensitively, with optional parameters" do
    expect(described_class.multipart_form_data?("multipart/form-data")).to be(true)
    expect(described_class.multipart_form_data?("Multipart/Form-Data; boundary=AaB03x")).to be(true)
    expect(described_class.multipart_form_data?(" MULTIPART/FORM-DATA ; boundary=x; charset=utf-8")).to be(true)

    expect(described_class.multipart_form_data?("multipart/form-dataevil")).to be(false)
    expect(described_class.multipart_form_data?("multipart/mixed; boundary=x")).to be(false)
    expect(described_class.multipart_form_data?(nil)).to be(false)
  end
end
