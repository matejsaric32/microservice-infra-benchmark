#!/usr/bin/env bash
# S2 — Startup latency measurement (feeds S5_stats.py --value startup_s)
#
# Definition used: pod creation -> Ready condition.
# Implemented as: wall clock from issuing `scale --replicas=1` until the pod's
# Ready condition becomes True, observed via kubectl's watch (not polling).
#
# The deployment is scaled to 0 and back to 1 each run, so the container image
# is already present on the node: this measures scheduling + container create +
# application init, NOT image pull. State that in §3.3.
#
# Emits: framework,run,startup_s,api_startup_s,pod
#   startup_s     — wall clock, millisecond resolution (report this)
#   api_startup_s — Kubernetes creationTimestamp -> Ready lastTransitionTime.
#                   ONE SECOND RESOLUTION. Cross-check only; never report.
#
# Usage: ./S2_startup_measure.sh <deployment> [N]
set -euo pipefail

FRAMEWORK="${1:-quarkus-reactive-perf-distroless}"
N="${2:-10}"
NAMESPACE="${NAMESPACE:-perf-test}"
OUT="${OUT:-startup_runs_${FRAMEWORK}.csv}"
SETTLE="${SETTLE:-10}"      # seconds at zero replicas before each run
DEADLINE="${DEADLINE:-330}" # hard per-run cap, seconds

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

kubectl -n "$NAMESPACE" get deploy "$FRAMEWORK" >/dev/null 2>&1 || {
  echo "no deployment '$FRAMEWORK' in namespace '$NAMESPACE'" >&2; exit 1; }

# Derive the pod selector from the deployment rather than assuming app=<name>.
SELECTOR=$(kubectl -n "$NAMESPACE" get deploy "$FRAMEWORK" \
  -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' \
  | sed 's/,$//')
[[ -n "$SELECTOR" ]] || { echo "deployment has no matchLabels selector" >&2; exit 1; }
echo "selector: $SELECTOR"

# Fail fast if the selector resolves to nothing while the deployment is up.
kubectl -n "$NAMESPACE" scale deploy "$FRAMEWORK" --replicas=1 >/dev/null
sleep 3
kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" --no-headers 2>/dev/null | grep -q . || {
  echo "selector '$SELECTOR' matches no pods — aborting rather than hanging" >&2; exit 1; }

[[ -f "$OUT" ]] || echo "framework,run,startup_s,api_startup_s,pod" > "$OUT"

pods_exist() {
  kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" --no-headers 2>/dev/null | grep -q .
}

wait_scaled_to_zero() {
  local deadline=$((SECONDS + 120))
  while pods_exist; do
    (( SECONDS < deadline )) || { echo "timeout draining $FRAMEWORK" >&2; return 1; }
    sleep 0.5
  done
}

echo "=== Startup: $FRAMEWORK, $N runs, ns=$NAMESPACE ==="

for i in $(seq 1 "$N"); do
  printf 'run %d/%d: draining... ' "$i" "$N"
  kubectl -n "$NAMESPACE" scale deploy "$FRAMEWORK" --replicas=0 >/dev/null
  wait_scaled_to_zero
  sleep "$SETTLE"
  printf 'starting... '

  T0=$(date +%s%N)
  kubectl -n "$NAMESPACE" scale deploy "$FRAMEWORK" --replicas=1 >/dev/null

  # `kubectl wait` errors immediately if the pod object does not exist yet, so
  # retry until it latches on. Once it does, it uses a watch — the return is
  # event-driven, not poll-quantized.
  run_deadline=$((SECONDS + DEADLINE))
  until kubectl -n "$NAMESPACE" wait --for=condition=Ready \
          pod -l "$SELECTOR" --timeout=300s >/dev/null 2>&1; do
    (( SECONDS < run_deadline )) || { echo; echo "run $i: never became Ready" >&2; exit 1; }
    sleep 0.05
  done
  T1=$(date +%s%N)

  STARTUP_S=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", (b-a)/1e9}')

  POD=$(kubectl -n "$NAMESPACE" get pod -l "$SELECTOR" \
          -o jsonpath='{.items[0].metadata.name}')
  CREATED=$(kubectl -n "$NAMESPACE" get pod "$POD" \
          -o jsonpath='{.metadata.creationTimestamp}')
  READY_AT=$(kubectl -n "$NAMESPACE" get pod "$POD" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')

  if [[ -n "$CREATED" && -n "$READY_AT" ]]; then
    API_S=$(( $(date -d "$READY_AT" +%s) - $(date -d "$CREATED" +%s) ))
  else
    API_S="NaN"
  fi

  printf 'ready\n'
  echo "$FRAMEWORK,$i,$STARTUP_S,$API_S,$POD" | tee -a "$OUT"
done

echo
echo "Wrote $OUT. Next:"
echo "  python3 S5_stats.py $OUT --group framework --value startup_s"