# frozen_string_literal: true

# Issue grouping needs the engine's meta database, which this experiment does
# not have yet. Exceptions are still stored and listed; they are not yet
# folded into Issues.
class GroupExceptionsJob < ApplicationJob
  def perform(_environment, _exception_ids) = nil
end
