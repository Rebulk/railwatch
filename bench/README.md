# bench/

Scripts that measure what the gem costs. Two are gates that CI runs
(`bundle exec rake bench`); the rest are for finding out where a number
comes from before changing the code that produces it. All of them boot the
dummy app in `spec/dummy` on SQLite through `bench/support.rb`, which also
provides `lantern_off!` / `lantern_on!`: the gem's notification subscribers
unsubscribed and its log capture detached, which is the only honest
baseline. Flipping `config.enabled` leaves everything wired in and hides
most of the cost.

Every number is CPU time on the thread doing the work, not wall time, so
the scripts are usable on a loaded box. Compare before and after within
one session on one machine; do not compare against numbers from another
day. Set a distinct `TEST_ENV_NUMBER` per concurrent run so the SQLite
files do not collide.

| Script | Question it answers |
|---|---|
| `overhead.rb` | **Gate.** Added CPU and allocations per request for three shapes, against limits. Fails if `Rails.logger.debug?` is on. |
| `no_db_writes.rb` | **Gate.** Did any INSERT/UPDATE/DELETE come from a frame inside `lib/lantern`? |
| `cost_by_shape.rb` | The gate's measurement over eight shapes, ungated, with `ROUNDS` and `BENCH_OUT` for before/after diffs. `LANTERN_REQUEST_SAMPLE_RATE=0` for the head-sampled-out path. |
| `request_path.rb` | The fixed per-request cost, piece by piece: execution start, request record fields, headers, user, session touch, log capture. |
| `query_path.rb` | The per-query cost: Rails' notification dispatch per subscriber style, the gem's SQL subscribers in each execution state, and the pieces of the subscriber body. |
| `exception_path.rb` | One unhandled exception: the whole `/boom` request off and on, with and without source snippets, sampled out, then capture and backtrace in isolation. |
| `transport_cost.rb` | Off the request thread: JSON and gzip CPU per record at each level, wire bytes per record and per request, heap per buffered record, GVL contention from the reporter thread. |
| `profile.rb` | Attribution: `memory_profiler` and `stackprof` over the trivial and 20-query requests, Lantern frames only, then wall profiles of the middleware, a cache fetch, and a log line. |
| `load/run.sh` | End to end under Puma with the real reporter thread shipping to `load/sink.ru`: throughput, latency, reporter CPU share, RSS, and what the sink received, per configuration. |

`profile.rb` needs the `bench` Gemfile group (`memory_profiler`); the rest
run with the default groups. `load/run.sh` reads `/proc` and is Linux only.

The numbers the docs quote, and how they were taken, are in
[`docs/faq.md`](../docs/faq.md).
