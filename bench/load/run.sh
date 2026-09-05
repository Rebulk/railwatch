#!/usr/bin/env bash
# End to end: the dummy app under Puma, real HTTP load, the real reporter
# thread shipping to bench/load/sink.ru. Prints throughput and latency per
# configuration, the reporter thread's share of process CPU, RSS growth,
# and what reached the sink (batches, gzip bytes, records, dropped).
#
# Start the sink first, in another terminal:
#   bundle exec puma -p 9393 -t 2:2 -q bench/load/sink.ru
# then:
#   bench/load/run.sh
#   DUR=15 CONC=8 PATHS="/widgets" ROUNDS=3 bench/load/run.sh
#
# Linux only (reads /proc). The box's other load shows up in every number,
# so compare configurations within one run, not across runs.
set -u
cd "$(dirname "$0")/../.."
PORT=${PORT:-9292}
SINK=${SINK:-http://127.0.0.1:9393}
DUR=${DUR:-8}
CONC=${CONC:-4}
PATHS=${PATHS:-/widgets /many /cached}
ROUNDS=${ROUNDS:-2}
export TEST_ENV_NUMBER=${TEST_ENV_NUMBER:-load}

curl -sf -o /dev/null "$SINK/stats" || { echo "no sink at $SINK; start it with: bundle exec puma -p 9393 -t 2:2 -q bench/load/sink.ru" >&2; exit 1; }
rm -f spec/dummy/storage/test${TEST_ENV_NUMBER}.sqlite3 spec/dummy/storage/test_queue${TEST_ENV_NUMBER}.sqlite3
bundle exec ruby bench/load/seed.rb

thread_cpu() { # pid, thread name prefix -> utime+stime ticks of matching threads
  local total=0
  for t in /proc/$1/task/*; do
    if [[ "$(cat "$t/comm" 2>/dev/null)" == "$2"* ]]; then
      local st; st=$(cut -d')' -f2 "$t/stat"); set -- $st
      total=$((total + ${12} + ${13}))
    fi
  done
  echo $total
}
proc_cpu() { local st; st=$(cut -d')' -f2 /proc/$1/stat); set -- $st; echo $((${12} + ${13})); }

run_config() {
  local label="$1"; shift
  env RAILS_ENV=test LANTERN_TOKEN=bench LANTERN_INGEST_URL="$SINK" "$@" \
    bundle exec puma -p "$PORT" -t 4:4 -w 0 -q spec/dummy/config.ru > /tmp/lantern_load_puma.log 2>&1 &
  local pid=$!
  for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/widgets" && break; sleep 0.5; done
  for _ in $(seq 1 200); do curl -s -o /dev/null "http://127.0.0.1:$PORT/widgets"; done  # warm
  sleep 3; curl -s "$SINK/stats?reset" > /dev/null
  echo "== $label"
  local rss0 cpu0 rep0; rss0=$(awk '/VmRSS/{print $2}' /proc/$pid/status); cpu0=$(proc_cpu $pid); rep0=$(thread_cpu $pid lantern-report)
  for p in $PATHS; do
    ruby bench/load/loadgen.rb -u "http://127.0.0.1:$PORT$p" -c "$CONC" -d "$DUR"
  done
  sleep 3  # let the reporter flush its last interval
  local rss1 cpu1 rep1; rss1=$(awk '/VmRSS/{print $2}' /proc/$pid/status); cpu1=$(proc_cpu $pid); rep1=$(thread_cpu $pid lantern-report)
  local cpu=$((cpu1 - cpu0)) rep=$((rep1 - rep0))
  echo "   puma cpu ${cpu}0ms total, reporter thread ${rep}0ms ($(( cpu > 0 ? rep * 100 / cpu : 0 ))%); rss $((rss0/1024))MB -> $((rss1/1024))MB; sink got $(curl -s "$SINK/stats")"
  kill $pid; wait $pid 2>/dev/null
}

for round in $(seq 1 "$ROUNDS"); do
  echo "### round $round  (load avg $(cut -d' ' -f1-3 /proc/loadavg))"
  run_config "disabled (LANTERN_ENABLED=0)" LANTERN_ENABLED=0
  run_config "enabled, sampled in" LANTERN_ENABLED=1
  run_config "enabled, requests sampled 10%" LANTERN_ENABLED=1 LANTERN_REQUEST_SAMPLE_RATE=0.1
  run_config "enabled, sampled out" LANTERN_ENABLED=1 LANTERN_REQUEST_SAMPLE_RATE=0
done
