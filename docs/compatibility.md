# Compatibility

Lantern supports Ruby 3.2, 3.3, 3.4, and 3.5 on Rails 7.2, 8.0, and 8.1.
The gemspec enforces those boundaries (`ruby >= 3.2`, `rails >= 7.2` and
`rails < 8.2`), and CI runs the complete matrix of all twelve combinations.

| | Rails 7.2 | Rails 8.0 | Rails 8.1 |
|---|---:|---:|---:|
| Ruby 3.2 | CI | CI | CI |
| Ruby 3.3 | CI | CI | CI |
| Ruby 3.4 | CI | CI | CI |
| Ruby 3.5 | CI | CI | CI |

Each Rails entry means the latest compatible patch release in that minor
series. A new Ruby or Rails minor is unsupported until it has a green matrix
entry. Removing a previously supported pair requires a Lantern release note
and a corresponding gemspec boundary change; a transient CI failure does not
silently redefine support.

The default `Gemfile.lock` remains the development baseline. The files under
`gemfiles/` constrain that same development and test bundle to each supported
Rails minor, so compatibility jobs exercise the full suite rather than a
reduced smoke test.

## Active Job and Solid Queue

Request-to-job trace propagation and the `enqueued_job`/`job_attempt` records
are built on Active Job notifications. They work for any adapter that follows
the Active Job contract, including Sidekiq, Resque, Delayed Job, Que, the
built-in async adapter, and custom adapters. The matrix directly exercises
Active Job's test and inline adapters without a Solid Queue worker.

Some telemetry necessarily uses Solid Queue's own notifications or tables:

- recurring jobs become `scheduled_task` records with schedule and drift;
- jobs failed when a worker process is pruned become failed `job_attempt`
  records even though Active Job never started them;
- health records include ready depth, per-queue depth, and worker counts;
- Solid Queue concurrency keys are attached when the job exposes one.

Those fields are absent, rather than guessed, under other adapters. Normal
enqueue, perform, retry, discard, exception, queue-latency, argument-shape,
identity, and trace telemetry remains available through Active Job.

## Rails-version additions

The shared request, job, query, exception, cache, mail, storage, view, and log
instrumentation runs across the entire matrix. Lantern also consumes newer
framework signals when the installed Rails version provides them:

- `Rails.event` structured log events require Rails 8.1; ordinary
  `Rails.logger` capture works on every supported version.
- Rails 8.1 adds the `rescue_from_callback.action_controller` notification,
  which lets Lantern report controller-rescued exceptions automatically.
  Exceptions reaching `Rails.error` or Lantern's Rack boundary are captured on
  every supported version.
- Rails 7.2 and 8.0 identify a rate-limited request but do not expose the
  limiter's name, count, or threshold in the notification. Rails 8.1 adds
  those details.
