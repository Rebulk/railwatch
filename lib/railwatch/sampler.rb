# frozen_string_literal: true

module Railwatch
  # Sampling is decided once per execution. Sampled-in ships the whole tree.
  # Unhandled exceptions in sampled-out executions still ship (governed by the
  # exceptions rate), which is exactly Nightwatch's behaviour.
  module Sampler
    module_function

    def decide(kind)
      configured = Railwatch.config.sample_rate(kind)
      rate = configured / Railwatch.reporter.backpressure_factor
      return true if rate >= 1.0
      return false if rate <= 0.0

      roll = Random.rand
      return true if roll < rate

      # Kept by the configured rate, lost to backpressure: counted, so the
      # reporter can say what an ingest refusal cost once it is over.
      Railwatch.reporter.note_sampled_out if roll < configured
      false
    end
  end
end
