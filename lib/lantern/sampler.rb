# frozen_string_literal: true

module Lantern
  # Sampling is decided once per execution. Sampled-in ships the whole tree.
  # Unhandled exceptions in sampled-out executions still ship (governed by the
  # exceptions rate), which is exactly Nightwatch's behaviour.
  module Sampler
    module_function

    def decide(kind)
      rate = Lantern.config.sample_rate(kind) / Lantern.reporter.backpressure_factor
      return true if rate >= 1.0
      return false if rate <= 0.0
      Random.rand < rate
    end
  end
end
