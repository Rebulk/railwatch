# frozen_string_literal: true

# Loads the dummy schema and a few rows into the test SQLite file so a
# Puma process can serve /widgets, /many, /cached. Run by bench/load/run.sh.
ENV["RAILS_ENV"] = "test"
ENV["LANTERN_ENABLED"] = "0"
require_relative "../../spec/dummy/config/environment"
ActiveRecord::Schema.verbose = false
load File.expand_path("../../spec/dummy/db/schema.rb", __dir__)
3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
User.create!(name: "bench", email: "bench@example.com")
puts "seeded #{Widget.count} widgets, #{Gadget.count} gadgets, #{User.count} user"
