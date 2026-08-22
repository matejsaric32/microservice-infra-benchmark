#!/usr/bin/env bash
# Batch S8 compute-endpoint load: all 8 frameworks x {1000,2000} RPS, 3 replicates.
# ITERATIONS scales inversely with RPS to hold ~30M iterations/sec aggregate,
# continuing the compute/100 (100x300000) -> compute/500 (500x60000) convention.
# Rows are appended straight into compute/<rps>/ as each replicate completes.
# Resumable: a framework/level whose CSV already holds 3 data rows is skipped.
# NOT set -e: one framework failing must not abort the remaining combinations.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> scripts/

FRAMEWORKS=(
  "actix actix-perf"
  "ktor ktor-perf"
  "quarkus-jvm quarkus-perf-jvm"
  "quarkus-native quarkus-perf-native"
  "quarkus-reactive-jvm quarkus-reactive-perf-jvm"
  "quarkus-reactive-native quarkus-reactive-perf-native"
  "spring spring-perf"
  "spring-reactor spring-reactor-perf"
)
# rps:iterations
LEVELS="${LEVELS:-1000:30000 2000:15000}"

for lvl in $LEVELS; do
  rps="${lvl%%:*}"; iters="${lvl##*:}"
  dir="compute/${rps}"
  mkdir -p "$dir"
  for pair in "${FRAMEWORKS[@]}"; do
    set -- $pair
    fw=$1; dep=$2
    out="${dir}/s8_compute_metrics_${fw}.csv"

    rows=0
    [[ -f "$out" ]] && rows=$(tail -n +2 "$out" | grep -c . || true)
    if (( rows >= 3 )); then
      echo "=== SKIP ${fw} @ ${rps} (already has ${rows} rows) ==="
      continue
    fi
    if (( rows > 0 )); then
      echo "=== RESET ${fw} @ ${rps} (partial: ${rows} rows) ==="
      rm -f "$out"
    fi

    echo
    echo "######## $(date +%H:%M:%S)  ${fw} @ ${rps} RPS x ${iters} iters  ########"
    OUT="$out" RPS="$rps" ITERATIONS="$iters" ./S8_load_with_metrics.sh "$fw" "$dep" 3
    echo "## exit=$? for ${fw} @ ${rps}"
  done
done

echo
echo "======== COMPUTE BATCH COMPLETE $(date +%H:%M:%S) ========"
for lvl in $LEVELS; do
  rps="${lvl%%:*}"
  for f in compute/${rps}/s8_compute_metrics_*.csv; do
    [[ -f "$f" ]] || continue
    printf '  %-50s %s rows\n' "$f" "$(tail -n +2 "$f" | grep -c . || true)"
  done
done
