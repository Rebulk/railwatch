# frozen_string_literal: true

module Railwatch
  # Issue.record_occurrence! replaces `sample` wholesale on every breach, but the
  # typed detector snapshot is durable context, not the latest reading. Capturing
  # it costs a telemetry query per detector run, so re-capture only when the
  # issue is newly open and otherwise carry the stored snapshot forward.
  module DetectionSnapshotting
    private

    def carry_detection(issue, outcome)
      detection = if outcome == :new || outcome == :regressed
        yield
      else
        issue.sample_previously_was&.dig("detection")
      end
      issue.update!(sample: issue.sample.merge("detection" => detection)) if detection
    end
  end
end
