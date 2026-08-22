#!/usr/bin/env bash
# S7 — Iso-load with server-side resource metrics (wraps S6_load.js + Prometheus)
#
# Runs the k6 iso-load test N times and, for each replicate, queries Prometheus
# over EXACTLY the k6 measured window (warm-up excluded) for CPU and memory.
#
# Why a wrapper: S6_load.js rewrites s6_<framework>.csv on every run, so N runs
# would leave only the last one. Each row is harvested and appended here instead.
#
# The Prometheus window is [T0+WARMUP_S, T0+WARMUP_S+MEASURE_S], matching the
# window k6 counts. Querying the whole test would let JIT/warm-up inflate both
# CPU and memory — the exact effect this benchmark exists to isolate.
#
# Emits: framework,run,rps,p50_ms,p95_ms,p99_ms,err_pct,achieved_rps,
#        cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit
#
# Usage: ./S7_load_with_metrics.sh <url-prefix> <deployment> [N]
set -euo pipefail

FRAMEWORK="${1:-quarkus-native}"       # k6 FRAMEWORK = ingress path prefix
DEPLOY="${2:-quarkus-perf-native}"     # k8s deployment (NOT the same string)
N="${3:-${N:-3}}"

NS="${NAMESPACE:-perf-test}"
TARGET="${TARGET:-http://localhost:31081}"   # ingress-nginx NodePort
ENDPOINT="${ENDPOINT:-/io/light}"
RPS="${RPS:-100}"
WARMUP_S="${WARMUP_S:-60}"
MEASURE_S="${MEASURE_S:-180}"
RESTART="${RESTART:-1}"                # cold pod per replicate
SETTLE="${SETTLE:-15}"                 # after Ready, before load
COOLDOWN="${COOLDOWN:-20}"             # let Prometheus ingest the tail (5s scrape)
PROM_PORT="${PROM_PORT:-9090}"
INGRESS_NAME="${INGRESS_NAME:-perf-ingress}"
INGRESS_TIMEOUT="${INGRESS_TIMEOUT:-120}"
PROM="http://localhost:${PROM_PORT}"
OUT="${OUT:-s7_load_metrics_${FRAMEWORK}.csv}"

for c in kubectl k6 curl jq; do
  command -v "$c" >/dev/null || { echo "$c not found" >&2; exit 1; }
done
kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || {
  echo "no deployment '$DEPLOY' in namespace '$NS'" >&2; exit 1; }

# --- Prometheus port-forward (ClusterIP only; not reachable from the host) ----
# Self-healing: the Prometheus pod being replaced mid-run breaks the forward,
# which previously aborted the whole test under `set -e`. Now a dead forward is
# re-established and the query retried; only a persistent failure yields NaN.
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

start_pf() {
  [[ -n "$PF_PID" ]] && { kill "$PF_PID" 2>/dev/null || true; }
  PF_PID=""
  curl -sf -o /dev/null "$PROM/-/ready" 2>/dev/null && return 0
  kubectl -n "$NS" port-forward svc/prometheus "${PROM_PORT}:9090" >/dev/null 2>&1 &
  PF_PID=$!
  local n
  for n in $(seq 1 40); do
    curl -sf -o /dev/null "$PROM/-/ready" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

ensure_prom() {
  curl -sf -o /dev/null "$PROM/-/ready" 2>/dev/null && return 0
  echo "  prometheus unreachable - re-establishing port-forward..." >&2
  start_pf
}

start_pf || { echo "cannot reach prometheus at $PROM" >&2; exit 1; }
echo "prometheus reachable at $PROM"

# Instant query evaluated AT a past timestamp -> scalar. Retries; never aborts.
pq_at() { # $1 = promql, $2 = eval time (unix), $3 = divisor
  local q="$1" t="$2" d="${3:-1}" raw="" attempt ok=0
  for attempt in 1 2 3; do
    if ensure_prom; then
      if raw=$(curl -sfG --max-time 20 "$PROM/api/v1/query" \
                 --data-urlencode "query=$q" --data-urlencode "time=$t" 2>/dev/null); then
        ok=1; break
      fi
    fi
    echo "  prometheus query attempt $attempt failed; retrying..." >&2
    raw=""; sleep 3
  done
  if [[ $ok -ne 1 || -z "$raw" ]]; then echo "NaN"; return 0; fi
  printf '%s' "$raw" | jq -r '.data.result[0].value[1] // "NaN"' \
    | awk -v d="$d" '{ if ($1=="NaN") print "NaN"; else printf "%.4f", $1/d }'
}

# nginx can keep routing to the OLD pod IP after a scale 0->1 cycle, returning
# 502 "Host is unreachable" against a perfectly healthy pod. Starting k6 in that
# state produces a run of pure timeouts that looks like a framework failure.
# Gate every run on the ingress actually serving 200, nudging nginx to resync.
wait_ingress_ready() {
  local url="${TARGET}/${FRAMEWORK}${ENDPOINT}?user_id=1"
  local deadline=$((SECONDS + INGRESS_TIMEOUT))
  local nudged=0 code=""
  while :; do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && { echo "  ingress ready (HTTP 200)"; return 0; }
    if (( SECONDS >= deadline )); then
      echo "  ingress never returned 200 for $url (last HTTP $code)" >&2
      return 1
    fi
    if (( nudged == 0 )) && (( SECONDS >= deadline - INGRESS_TIMEOUT + 20 )); then
      echo "  ingress HTTP $code - forcing nginx resync..." >&2
      kubectl -n "$NS" annotate ingress "$INGRESS_NAME" \
        resync-ts="$(date +%s)" --overwrite >/dev/null 2>&1 || true
      nudged=1
    fi
    sleep 2
  done
}

wait_drained() {
  local deadline=$((SECONDS + 120))
  while kubectl -n "$NS" get pods -l app="$DEPLOY" --no-headers 2>/dev/null | grep -q .; do
    (( SECONDS < deadline )) || { echo "timeout draining $DEPLOY" >&2; return 1; }
    sleep 0.5
  done
}

[[ -f "$OUT" ]] || echo "framework,run,rps,p50_ms,p95_ms,p99_ms,err_pct,achieved_rps,cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit" > "$OUT"

echo "=== S7: $FRAMEWORK ($DEPLOY), $N runs, ${RPS} RPS, ${WARMUP_S}s warmup + ${MEASURE_S}s measured ==="
echo "    target: ${TARGET}/${FRAMEWORK}${ENDPOINT}   restart-between-runs: $RESTART"

K6_CSV="s6_${FRAMEWORK//[^A-Za-z0-9._-]/_}.csv"

for i in $(seq 1 "$N"); do
  echo
  echo "--- run $i/$N ---"

  if [[ "$RESTART" == "1" ]]; then
    printf 'cold restart: draining... '
    kubectl -n "$NS" scale deploy "$DEPLOY" --replicas=0 >/dev/null
    wait_drained
    kubectl -n "$NS" scale deploy "$DEPLOY" --replicas=1 >/dev/null
    kubectl -n "$NS" wait --for=condition=Ready pod -l app="$DEPLOY" --timeout=300s >/dev/null 2>&1 \
      || { until kubectl -n "$NS" wait --for=condition=Ready pod -l app="$DEPLOY" --timeout=300s >/dev/null 2>&1; do sleep 0.5; done; }
    printf 'ready, settling %ss\n' "$SETTLE"
    sleep "$SETTLE"
  fi

  POD=$(kubectl -n "$NS" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}')
  echo "pod: $POD"

  if ! wait_ingress_ready; then
    echo "run $i: ingress not routing to $DEPLOY - aborting rather than recording a bogus row." >&2
    echo "  (pod is likely healthy; check: kubectl -n $NS get endpointslice -l kubernetes.io/service-name=$DEPLOY)" >&2
    exit 1
  fi

  PROM_POD_START=$(kubectl -n "$NS" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  rm -f "$K6_CSV"
  T0=$(date +%s)
  set +e
  k6 run --quiet \
     -e TARGET="$TARGET" -e FRAMEWORK="$FRAMEWORK" -e ENDPOINT="$ENDPOINT" \
     -e RPS="$RPS" -e WARMUP_S="$WARMUP_S" -e MEASURE_S="$MEASURE_S" \
     S6_load.js
  K6_EXIT=$?
  set -e
  [[ $K6_EXIT -ne 0 ]] && echo "note: k6 exit=$K6_EXIT (threshold breach or error) — row still recorded"

  W_END=$((T0 + WARMUP_S + MEASURE_S))
  echo "measured window: $(date -d @$((T0+WARMUP_S)) +%H:%M:%S) -> $(date -d @${W_END} +%H:%M:%S)"

  echo "waiting ${COOLDOWN}s for Prometheus to ingest the window tail..."
  sleep "$COOLDOWN"

  # A Prometheus restart mid-window silently truncates the series it serves,
  # so flag it rather than reporting a quietly-wrong average.
  PROM_POD_NOW=$(kubectl -n "$NS" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$PROM_POD_START" && "$PROM_POD_NOW" != "$PROM_POD_START" ]]; then
    echo "  WARNING: prometheus pod changed during run $i ($PROM_POD_START -> $PROM_POD_NOW);" >&2
    echo "           CPU/memory for this run may be incomplete." >&2
  fi

  SEL="namespace=\"$NS\",pod=\"$POD\",container!=\"\""
  MEM_AVG=$(pq_at "avg_over_time(container_memory_working_set_bytes{$SEL}[${MEASURE_S}s])" "$W_END" 1048576)
  MEM_MAX=$(pq_at "max_over_time(container_memory_working_set_bytes{$SEL}[${MEASURE_S}s])" "$W_END" 1048576)
  CPU_AVG=$(pq_at "avg_over_time(rate(container_cpu_usage_seconds_total{$SEL}[1m])[${MEASURE_S}s:5s])" "$W_END")
  CPU_MAX=$(pq_at "max_over_time(rate(container_cpu_usage_seconds_total{$SEL}[1m])[${MEASURE_S}s:5s])" "$W_END")

  if [[ -f "$K6_CSV" ]]; then
    ROW=$(tail -n1 "$K6_CSV")
    IFS=, read -r _f _rps P50 P95 P99 ERR ARPS <<< "$ROW"
  else
    echo "WARNING: $K6_CSV missing — k6 produced no summary" >&2
    P50=NaN; P95=NaN; P99=NaN; ERR=NaN; ARPS=NaN
  fi

  echo "$FRAMEWORK,$i,$RPS,$P50,$P95,$P99,$ERR,$ARPS,$CPU_AVG,$CPU_MAX,$MEM_AVG,$MEM_MAX,$POD,$K6_EXIT" | tee -a "$OUT"
done

echo
echo "Wrote $OUT. Next:"
echo "  python3 S5_stats.py $OUT --group framework --value p95_ms"
echo "  python3 S5_stats.py $OUT --group framework --value cpu_avg_cores"
echo "  python3 S5_stats.py $OUT --group framework --value mem_avg_mib"
