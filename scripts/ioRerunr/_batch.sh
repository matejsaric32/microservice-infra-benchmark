#!/usr/bin/env bash
# Batch S7 iso-load rerun: all 8 frameworks x {500,1000,2000} RPS, 3 replicates.
# Rows are appended straight into ioRerunr/<rps>/ as each replicate completes.
# Resumable: a framework/level whose CSV already holds 3 data rows is skipped,
# so re-invoking after an interruption picks up where it stopped.
# NOT set -e: one framework failing (ingress never ready, pod crashloop) must not
# abort the remaining 23 framework/level combinations.
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
LEVELS="${LEVELS:-500 1000 2000}"

for rps in $LEVELS; do
  dir="ioRerunr/${rps}"
  mkdir -p "$dir"
  for pair in "${FRAMEWORKS[@]}"; do
    set -- $pair
    fw=$1; dep=$2
    out="${dir}/s7_load_metrics_${fw}.csv"

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
    echo "######## $(date +%H:%M:%S)  ${fw} @ ${rps} RPS  ########"
    OUT="$out" RPS="$rps" ./S7_load_with_metrics.sh "$fw" "$dep" 3
    echo "## exit=$? for ${fw} @ ${rps}"
  done
done

echo
echo "======== BATCH COMPLETE $(date +%H:%M:%S) ========"
for rps in $LEVELS; do
  for f in ioRerunr/${rps}/s7_load_metrics_*.csv; do
    [[ -f "$f" ]] || continue
    printf '  %-46s %s rows\n' "$f" "$(tail -n +2 "$f" | grep -c . || true)"
  done
done
