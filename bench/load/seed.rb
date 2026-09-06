# frozen_string_literal: true

# Loads the dummy schema and a few rows into the test SQLite file so a
# Puma process can serve /widgets, /many, /cached. Run by bench/load/run.sh.
require_relative "../support"
puts "seeded #{Widget.count} widgets, #{Gadget.count} gadgets, #{User.count} user"
