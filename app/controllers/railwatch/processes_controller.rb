# frozen_string_literal: true

module Railwatch
    class ProcessesController < DashboardController
    def index
      live_since = Telemetry::HealthSample::LIVE_WINDOW.ago
      samples, series, queues, live_servers, processes = telemetry do
        live = Telemetry::HealthSample.live(live_since).to_a
        [ live, Telemetry::HealthSample.series(*window_range, bucket: Telemetry::Aggregations::STEPS.fetch(step_key)), Telemetry::HealthSample.queue_depths(live),
          live.map(&:server) | Telemetry::Execution.servers_since(live_since),
          Telemetry::Process.recent.limit(200).to_a ]
      end
      render inertia: { samples: samples.map { |s| sample_row(s) }, series: series, queues: queues,
                        silent_servers: environment.expected_servers - live_servers.compact,
                        processes: processes.map { |p| process_row(p) } }
    end

    private

    def sample_row(s)
      { id: s.id, server: s.server, role: s.role, pid: s.pid, deploy: s.deploy, sampled_at: s.sampled_at,
        threads_busy: s.threads_busy, threads_max: s.threads_max, backlog: s.backlog,
        pool_busy: s.pool_busy, pool_size: s.pool_size, pool_waiting: s.pool_waiting,
        queue_depth: s.queue_depth, queue_latency: s.queue_latency && (s.queue_latency / 1000.0).round(1), memory: s.memory }
    end

    def process_row(p)
      { id: p.id, booted_at: p.booted_at, pid: p.pid, role: p.role, server: p.server, deploy: p.deploy,
        ruby_version: p.ruby_version, rails_version: p.rails_version, railwatch_version: p.railwatch_version,
        boot_seconds: p.boot_seconds, detail: p.detail }
    end
    end
end
