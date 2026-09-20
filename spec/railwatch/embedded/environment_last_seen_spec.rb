# frozen_string_literal: true

require "spec_helper"

# A nil last_seen_at is what the dashboard reads as "no events yet", and it
# answers with the install steps -- the gem, the generator, the token, run the
# doctor. That is right for an environment that has never reported and wrong
# for every other one, so where this value comes from decides whether a working
# install can see its own data.
#
# It used to be a module-level accessor on Railwatch::Embedded, set by whatever
# process ingested the batch. A deployed embedded install ingests in the writer
# process that the Puma plugin forks and renders the dashboard in a web one, so
# the web process never saw it set and offered the install steps forever. A
# single-process run -- this suite before these examples, and any development
# boot -- could not reproduce that, which is how it shipped.
RSpec.describe Railwatch::Environment do
  let(:environment) { described_class.current }

  describe "#last_seen_at" do
    it "is nil while nothing has been ingested" do
      environment.with_telemetry { Railwatch::Telemetry::IngestBatch.delete_all }

      expect(environment.last_seen_at).to be_nil
    end

    it "reports the newest batch, so any process that can read the database can tell" do
      newest = Time.current.change(usec: 0)

      environment.with_telemetry do
        Railwatch::Telemetry::IngestBatch.delete_all
        Railwatch::Telemetry::IngestBatch.create!(received_at: newest - 5.minutes, accepted: 1, rejected: 0, bytes: 10)
        Railwatch::Telemetry::IngestBatch.create!(received_at: newest, accepted: 1, rejected: 0, bytes: 10)
      end

      expect(environment.last_seen_at).to be_within(1.second).of(newest)
    end

    # Batches are written concurrently, so the row inserted last is not
    # necessarily the one received last. Taking the newest id would let the
    # displayed time go backwards when they disagree.
    it "takes the newest receipt time even when a later row recorded an earlier one" do
      newest = Time.current.change(usec: 0)

      environment.with_telemetry do
        Railwatch::Telemetry::IngestBatch.delete_all
        Railwatch::Telemetry::IngestBatch.create!(received_at: newest, accepted: 1, rejected: 0, bytes: 10)
        # Inserted after, received before: the interleaving this guards.
        Railwatch::Telemetry::IngestBatch.create!(received_at: newest - 10.minutes, accepted: 1, rejected: 0, bytes: 10)
      end

      expect(environment.last_seen_at).to be_within(1.second).of(newest)
    end

    # The regression itself: ingest recorded in one place and the dashboard
    # read another. Touching the environment the way Ingest::Batch does must
    # not be what makes the value appear, because in production the process
    # doing the touching is not the process doing the reading.
    it "does not depend on this process having ingested anything" do
      recorded = Time.current.change(usec: 0)
      environment.with_telemetry do
        Railwatch::Telemetry::IngestBatch.delete_all
        Railwatch::Telemetry::IngestBatch.create!(received_at: recorded, accepted: 1, rejected: 0, bytes: 10)
      end

      # Whatever a writer process would have set in memory, this one has not.
      expect(Railwatch::Embedded).not_to respond_to(:last_seen_at)
      expect(environment.last_seen_at).to be_within(1.second).of(recorded)
    end
  end
end
