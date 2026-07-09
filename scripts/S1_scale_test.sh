#!/usr/bin/env bash
# S1 — Scale up/down latency (feeds S5_stats.py --value scaleup_s / scaledown_s)
#
# Definition used: time from issuing the scale command until the Deployment's
# .status.readyReplicas reaches the target. Scale-down therefore measures
# convergence of the *ready* set, and deliberately EXCLUDES kubelet's
# termination grace period — the old script counted Terminating pods and then
# ran a second `kubectl wait` inside the timed region, inflating scale-down by
# the grace period. State this definition in §3.3.
#
# Emits: framework,run,scaleup_s,scaledown_s,min_replicas,max_replicas
#
# Usage: ./S1_scale_test.sh <deployment> [min] [max] [N]
set -euo pipefail

FRAMEWORK="${1:-quarkus-reactive-perf-distroless}"
MIN_REPLICAS="${2:-1}"
MAX_REPLICAS="${3:-10}"
N="${4:-10}"
NAMESPACE="${NAMESPACE:-perf-test}"
OUT="${OUT:-scaling_runs_${FRAMEWORK}.csv}"
POLL="${POLL:-0.1}"
DEADLINE="${DEADLINE:-300}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

[[ -f "$OUT" ]] || \
  echo "framework,run,scaleup_s,scaledown_s,min_replicas,max_replicas" > "$OUT"

ready_replicas() {
  local r
  r=$(kubectl -n "$NAMESPACE" get deploy "$FRAMEWORK" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  echo "${r:-0}"   # field is absent, not 0, when nothing is ready
}

wait_ready() { # $1 = target count
  local target=$1 deadline=$((SECONDS + DEADLINE))
  while [[ "$(ready_replicas)" != "$target" ]]; do
    (( SECONDS < deadline )) || { echo "timeout waiting for $target ready" >&2; return 1; }
    sleep "$POLL"
  done
}

elapsed_s() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", (b-a)/1e9}'; }

echo "=== Scale: $FRAMEWORK, $MIN_REPLICAS<->$MAX_REPLICAS, $N runs ==="

for i in $(seq 1 "$N"); do
  # Establish the baseline OUTSIDE the timed region.
  kubectl -n "$NAMESPACE" scale deploy "$FRAMEWORK" --replicas="$MIN_REPLICAS" >/dev/null
  wait_ready "$MIN_REPLICAS"
  sleep 5

  T0=$(date +%s%N)
  kubectl -n "$NAMESPACE" scale deploy "$FRAMEWORK" --replicas="$MAX_REPLICAS" >/dev/null
  wait_ready "$MAX_REPLICAS"
  T1=$(date +%s%N)
  UP=$(elapsed_s "$T0" "$T1")

  sleep 5

  T2=$(date +%s%N)
  kubectl -n "$NAMESPACE" scale deploy "$FRAMEWORK" --replicas="$MIN_REPLICAS" >/dev/null
  wait_ready "$MIN_REPLICAS"
  T3=$(date +%s%N)
  DOWN=$(elapsed_s "$T2" "$T3")

  echo "$FRAMEWORK,$i,$UP,$DOWN,$MIN_REPLICAS,$MAX_REPLICAS" | tee -a "$OUT"
done

echo
echo "Wrote $OUT. Next:"
echo "  python3 S5_stats.py $OUT --group framework --value scaleup_s"
echo "  python3 S5_stats.py $OUT --group framework --value scaledown_s"