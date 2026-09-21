# frozen_string_literal: true

require "spec_helper"

# There is one browser client: the file the dashboard bundle is built from,
# which the install generator copies and Railwatch Cloud imports.
RSpec.describe "browser client" do
  it "is the shipped file" do
    expect(Railwatch.browser_client_path).to eq(File.expand_path("../../app/frontend/lib/railwatch.ts", __dir__))
    expect(File).to exist(Railwatch.browser_client_path)
    expect(Railwatch::Packaging.specification.files).to include(Railwatch::Packaging::BROWSER_CLIENT)
  end

  it "writes the session cookie Railwatch::Sessions reads" do
    cookie = File.read(Railwatch.browser_client_path)[/document\.cookie = `([a-z_]+)=/, 1]
    expect("#{cookie}=abc").to match(Railwatch::Sessions::COOKIE)
  end
end
