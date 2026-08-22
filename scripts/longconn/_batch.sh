#!/usr/bin/env bash
# Batch S10 long-lived-connection sweep: one framework at a time, 5 levels
# (0..2000) x 3 replicates each, results in longconn/<framework>/.
#
# STRICTLY SEQUENTIAL, and it waits for any S10 already in flight before
# starting: two k6 generators running at once would contend for the host CPU
# and inflate both sweeps' latency and CPU numbers.
#
# Resumable: a framework whose CSV already holds 15 data rows (5 levels x 3) is
# skipped; a partial CSV is reset and the framework rerun from scratch, because
# S10 appends and a half-finished sweep cannot be resumed mid-level.
# NOT set -e: one framework failing must not abort the rest of the queue.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> scripts/

# framework-label  deployment  nodePort   (ports per longconn/ and the README table)
FRAMEWORKS=(
  "quarkus-native quarkus-perf-native 31095"
  "quarkus-reactive-jvm quarkus-reactive-perf-jvm 31096"
  "quarkus-reactive-native quarkus-reactive-perf-native 31097"
)

LEVELS="${LEVELS:-0 100 500 1000 2000}"
REPS="${REPS:-3}"
K6_CPUS="${K6_CPUS:-16-31}"
EXPECT=$(( $(printf '%s\n' $LEVELS | wc -w) * REPS ))

wait_for_free() {
  local waited=0
  while pgrep -f "S10_longconn_with_metrics.sh" >/dev/null; do
    (( waited % 300 == 0 )) && echo "$(date +%H:%M:%S) waiting for the running sweep to finish..."
    sleep 30; waited=$(( waited + 30 ))
  done
}

echo "======== LONGCONN BATCH START $(date +%H:%M:%S) ========"
echo "queue: quarkus-native -> quarkus-reactive-jvm -> quarkus-reactive-native   levels: $LEVELS   reps: $REPS"
wait_for_free

for triple in "${FRAMEWORKS[@]}"; do
  set -- $triple
  fw=$1; dep=$2; port=$3
  dir="longconn/${fw}"
  out="${dir}/s10_longconn_${fw}.csv"
  mkdir -p "$dir"

  rows=0
  [[ -f "$out" ]] && rows=$(tail -n +2 "$out" | grep -c . || true)
  if (( rows >= EXPECT )); then
    echo "=== SKIP ${fw} (already has ${rows} rows) ==="
    continue
  fi
  if (( rows > 0 )); then
    echo "=== RESET ${fw} (partial: ${rows} rows) ==="
    rm -f "$out"
  fi

  echo
  echo "######## $(date +%H:%M:%S)  ${fw} (${dep}) via nodePort ${port}  ########"
  ( cd "$dir" && LEVELS="$LEVELS" K6_CPUS="$K6_CPUS" \
      ../../S10_longconn_with_metrics.sh "$fw" "$dep" "$port" "$REPS" 2>&1 | tee run.log )
  echo "## finished ${fw} at $(date +%H:%M:%S)"
done

echo
echo "======== LONGCONN BATCH COMPLETE $(date +%H:%M:%S) ========"
for f in longconn/*/s10_longconn_*.csv; do
  [[ -f "$f" ]] || continue
  printf '  %-50s %s rows\n' "$f" "$(tail -n +2 "$f" | grep -c . || true)"
done
