# frozen_string_literal: true

require "spec_helper"

# The bench/ scripts reach into the request middleware's private methods
# to time them one by one, and nothing else runs them (rake bench runs only
# the overhead and no-DB-writes gates), so a changed signature broke
# bench/request_path.rb unnoticed. Each such call must pass the arguments
# the method takes.
RSpec.describe "bench scripts" do
  it "call the request middleware's private methods with as many arguments as they take" do
    calls = Dir[File.expand_path("../../bench/*.rb", __dir__)].flat_map do |file|
      File.read(file).scan(/\bmw\.send\(:(\w+)((?:, *[^,)]+)*)\)/).map { |name, args| [ File.basename(file), name, args.count(",") ] }
    end
    expect(calls).not_to be_empty

    calls.each do |file, name, given|
      method = Railwatch::Middleware::Request.instance_method(name.to_sym)
      required = method.parameters.count { |kind, _| kind == :req }
      optional = method.parameters.count { |kind, _| kind == :opt }
      expect(given).to be_between(required, required + optional), "#{file}: #{name} takes #{required}..#{required + optional} arguments, given #{given}"
    end
  end
end
