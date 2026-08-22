#!/usr/bin/env bash
# S10 — long-lived-connection sweep with server-side resource metrics
#       (wraps S9_longconn.js + Prometheus)
#
# Same harness as S7_load_with_metrics.sh / S8_load_with_metrics.sh, but instead
# of repeating one load level N times it sweeps a *connection* level: for each
# level in LEVELS (0 = baseline with no connections at all) it restarts the pod
# cold, holds that many keep-alive connections open against /noop, and queries
# Prometheus over EXACTLY the k6 measured window for CPU and memory. The slope
# of mem_avg_mib against conns is the per-connection cost of the framework.
#
# Why a cold pod per level: connection-table state, thread pools grown under a
# previous level and JVM heap that has already expanded do not shrink back, so
# reusing a pod would carry the previous level's cost into the next one and
# flatten the slope.
#
# Why NOT the ingress: connections opened against NGINX terminate on the ingress
# controller, which serves them from its own upstream pool. The pod would see a
# few hundred connections regardless of the client count. S9 therefore targets
# the framework's <deployment>-direct NodePort Service (longconn/), where
# kube-proxy only DNATs and pod connections == VUs. This is a deliberate
# deviation from the S6/S7 routing path and must be stated in the methodology;
# the *measurement* path is unchanged (container-level cAdvisor metrics, no
# in-application instrumentation).
#
# Emits: framework,conns,run,p50_ms,p95_ms,p99_ms,err_pct,mean_conn_ms,max_conn_ms,
#        measured_reqs,achieved_rps,max_vus,est_conns_host,cpu_avg_cores,cpu_max_cores,
#        mem_avg_mib,mem_max_mib,pod,k6_exit
#
# Usage: ./S10_longconn_with_metrics.sh <framework-label> <deployment> <nodePort> [reps]
#    e.g. ./S10_longconn_with_metrics.sh spring spring-perf 31090 3
#         LEVELS="0 100 500 1000 2000 5000" ./S10_longconn_with_metrics.sh actix actix-perf 31092
set -euo pipefail

FRAMEWORK="${1:-spring}"           # label only; used for CSV names, not routing
DEPLOY="${2:-spring-perf}"         # k8s deployment (NOT the same string)
PORT="${3:-31090}"                 # nodePort of <deployment>-direct
REPS="${4:-${REPS:-3}}"

NS="${NAMESPACE:-perf-test}"
HOST="${HOST:-http://localhost}"                  # node address; NodePort is appended
ENDPOINT="${ENDPOINT:-/noop}"
LEVELS="${LEVELS:-0 100 500 1000 2000}"           # 0 = baseline, no connections
THINK_S="${THINK_S:-2}"                           # 1 request / connection / THINK_S; MUST stay
                                                  # below the shortest server keep-alive timeout
                                                  # in the comparison (Actix defaults to 5 s)
RAMP_S="${RAMP_S:-30}"
HOLD_S="${HOLD_S:-240}"
MEASURE_S="${MEASURE_S:-180}"                     # trailing window that counts
RESTART="${RESTART:-1}"                           # cold pod per level+replicate
SETTLE="${SETTLE:-60}"                            # after Ready, before connections
COOLDOWN="${COOLDOWN:-20}"                        # let Prometheus ingest the tail (5s scrape)
K6_CPUS="${K6_CPUS:-}"                            # e.g. 16-31: keep the generator off the pod's cores
PROM_PORT="${PROM_PORT:-9090}"
PROM_WAIT="${PROM_WAIT:-300}"                     # tolerate a Prometheus pod reschedule at startup
METRIC_TIMEOUT="${METRIC_TIMEOUT:-60}"            # how long to wait for the pod's cAdvisor series
NODEPORT_TIMEOUT="${NODEPORT_TIMEOUT:-120}"
PROM="http://localhost:${PROM_PORT}"
TARGET="${HOST}:${PORT}"
OUT="${OUT:-s10_longconn_${FRAMEWORK}.csv}"
ENV_OUT="${ENV_OUT:-s10_longconn_env_${FRAMEWORK}.txt}"

for c in kubectl k6 curl jq; do
  command -v "$c" >/dev/null || { echo "$c not found" >&2; exit 1; }
done
kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || {
  echo "no deployment '$DEPLOY' in namespace '$NS'" >&2; exit 1; }
kubectl -n "$NS" get svc "${DEPLOY}-direct" >/dev/null 2>&1 || {
  echo "no Service '${DEPLOY}-direct' in namespace '$NS'." >&2
  echo "apply it first: kubectl apply -f longconn/" >&2; exit 1; }

SVC_PORT=$(kubectl -n "$NS" get svc "${DEPLOY}-direct" -o jsonpath='{.spec.ports[0].nodePort}')
[[ "$SVC_PORT" == "$PORT" ]] || {
  echo "port mismatch: ${DEPLOY}-direct is on nodePort $SVC_PORT, not $PORT" >&2; exit 1; }

# --- Client-side limits ------------------------------------------------------
# 5000 VUs plus k6 internals exhausts the default 1024 descriptors immediately,
# and a client that cannot open the connections produces a flat memory curve
# that reads as framework efficiency. Raise first, verify, and record.
MAX_LEVEL=$(printf '%s\n' $LEVELS | sort -n | tail -1)
WANT_NOFILE=$(( MAX_LEVEL * 4 + 8192 ))
ulimit -n "$WANT_NOFILE" 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
NOFILE=$(ulimit -n)
if (( NOFILE < WANT_NOFILE )); then
  echo "WARNING: file descriptor limit is $NOFILE, wanted $WANT_NOFILE for $MAX_LEVEL connections." >&2
  echo "         Raise the hard limit (ulimit -Hn) or lower LEVELS." >&2
fi

# Configuration that is pinned and reported: a difference in per-connection cost
# must not turn out to be a difference in a client-side default.
PORT_RANGE=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null | tr '\t' '-' || echo unknown)
{
  echo "framework      : $FRAMEWORK ($DEPLOY), nodePort $PORT"
  echo "levels         : $LEVELS   reps: $REPS"
  echo "timing         : think=${THINK_S}s ramp=${RAMP_S}s hold=${HOLD_S}s measured=${MEASURE_S}s settle=${SETTLE}s"
  echo "client nofile  : $NOFILE (wanted $WANT_NOFILE)"
  echo "ephemeral ports: $PORT_RANGE"
  echo "k6 version     : $(k6 version 2>/dev/null | head -1)"
  echo "k6 cpu pinning : ${K6_CPUS:-none}"
  echo "host cpus      : $(nproc)"
  echo "pod limits     : $(kubectl -n "$NS" get deploy "$DEPLOY" \
       -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null)"
} | tee "$ENV_OUT"
echo

TASKSET=()
if [[ -n "$K6_CPUS" ]]; then
  command -v taskset >/dev/null && TASKSET=(taskset -c "$K6_CPUS") \
    || echo "WARNING: taskset not found; k6 will not be pinned off the pod's cores" >&2
fi

# --- Prometheus port-forward (ClusterIP only; not reachable from the host) ----
# Self-healing: the Prometheus pod being replaced mid-sweep breaks the forward,
# which would otherwise abort the whole run under `set -e`. A dead forward is
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

# A single failed attempt used to abort the framework outright, which cost a
# whole queued sweep when the Prometheus pod was mid-reschedule (its Service had
# no ready endpoint for ~2 min). Keep trying for PROM_WAIT before giving up.
prom_deadline=$((SECONDS + PROM_WAIT))
until start_pf; do
  if (( SECONDS >= prom_deadline )); then
    echo "cannot reach prometheus at $PROM after ${PROM_WAIT}s" >&2; exit 1
  fi
  echo "  prometheus not ready yet - retrying (${PROM_WAIT}s budget)..." >&2
  sleep 10
done
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

# Unlike the ingress path used by S7/S8, a NodePort needs no nginx resync — but
# kube-proxy still needs the new pod in the EndpointSlice before it will route,
# so gate every level on the direct port actually serving 200.
wait_nodeport_ready() {
  local url="${TARGET}${ENDPOINT}"
  local deadline=$((SECONDS + NODEPORT_TIMEOUT))
  local code=""
  while :; do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && { echo "  nodePort ready (HTTP 200 on $url)"; return 0; }
    if (( SECONDS >= deadline )); then
      echo "  nodePort never returned 200 for $url (last HTTP $code)" >&2
      return 1
    fi
    sleep 2
  done
}

# cAdvisor is scraped through the API server proxy, so a pod-network hiccup takes
# the metric out while Prometheus itself still answers queries: pq_at then returns
# a well-formed empty result and the row lands with NaN in every resource column.
# A whole 4.5 h sweep was lost that way. Prove the series exists for THIS pod
# before spending a run on it, and wait a little in case the scrape is just late.
wait_pod_metrics() { # $1 = pod
  local q="container_memory_working_set_bytes{namespace=\"$NS\",pod=\"$1\",container!=\"\"}"
  local deadline=$((SECONDS + METRIC_TIMEOUT)) v=""
  while :; do
    v=$(pq_at "$q" "$(date +%s)" 1048576)
    [[ "$v" != "NaN" ]] && { echo "  cAdvisor metrics present for pod ($v MiB)"; return 0; }
    if (( SECONDS >= deadline )); then
      echo "  no cAdvisor series for pod $1 after ${METRIC_TIMEOUT}s" >&2
      return 1
    fi
    sleep 5
  done
}

wait_drained() {
  local deadline=$((SECONDS + 120))
  while kubectl -n "$NS" get pods -l app="$DEPLOY" --no-headers 2>/dev/null | grep -q .; do
    (( SECONDS < deadline )) || { echo "timeout draining $DEPLOY" >&2; return 1; }
    sleep 0.5
  done
}

# Independent, image-agnostic check that the connections really exist: count the
# host's ESTABLISHED sockets whose destination is the NodePort. k6's own max_vus
# is the client's belief; this is the kernel's. Sampled mid-measured-window.
# Expect conns + 1: k6's setup() preflight holds one connection of its own.
sample_est_conns() { # $1 = outfile
  if command -v ss >/dev/null; then
    ss -Htn state established "dst :${PORT}" 2>/dev/null | wc -l > "$1" || echo NaN > "$1"
  else
    echo NaN > "$1"
  fi
}

[[ -f "$OUT" ]] || echo "framework,conns,run,p50_ms,p95_ms,p99_ms,err_pct,mean_conn_ms,max_conn_ms,measured_reqs,achieved_rps,max_vus,est_conns_host,cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit" > "$OUT"

TOTAL=$(( $(printf '%s\n' $LEVELS | wc -w) * REPS ))
RUN_S=$(( RAMP_S + HOLD_S ))
echo "=== S10: $FRAMEWORK ($DEPLOY) via $TARGET$ENDPOINT ==="
echo "    levels: $LEVELS   reps: $REPS   ${TOTAL} runs x ~$(( (RUN_S + SETTLE + COOLDOWN) / 60 ))min"
echo "    cold restart between runs: $RESTART"

K6_SAFE="${FRAMEWORK//[^A-Za-z0-9._-]/_}"

for C in $LEVELS; do
for i in $(seq 1 "$REPS"); do
  echo
  echo "--- conns=$C  run $i/$REPS ---"

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

  if ! wait_nodeport_ready; then
    echo "conns=$C run $i: nodePort not routing to $DEPLOY - aborting rather than recording a bogus row." >&2
    echo "  (check: kubectl -n $NS get endpointslice -l kubernetes.io/service-name=${DEPLOY}-direct)" >&2
    exit 1
  fi

  if ! wait_pod_metrics "$POD"; then
    echo "conns=$C run $i: cAdvisor is not being scraped - aborting rather than writing NaN rows." >&2
    echo "  check: the kubernetes-cadvisor targets in Prometheus, and pod-to-apiserver connectivity" >&2
    echo "  (the sweep can be resumed once metrics return; rows already written are unaffected)" >&2
    exit 1
  fi

  PROM_POD_START=$(kubectl -n "$NS" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  K6_CSV="s9_${K6_SAFE}_${C}.csv"
  EST_FILE=$(mktemp)
  T0=$(date +%s)

  if [[ "$C" -eq 0 ]]; then
    # Baseline: an idle pod, no connections at all. Everything above this level
    # is measured against it, so it must be timed exactly like a loaded run.
    echo "baseline: idle for $(( RUN_S ))s, no connections"
    ( sleep $(( RUN_S - MEASURE_S / 2 )); sample_est_conns "$EST_FILE" ) &
    SAMPLER=$!
    sleep "$RUN_S"
    K6_EXIT=0
    P50=0; P95=0; P99=0; ERR=0; CONN_MEAN=0; CONN_MAX=0; REQS=0; ARPS=0; MAXVU=0
  else
    ( sleep $(( RUN_S - MEASURE_S / 2 )); sample_est_conns "$EST_FILE" ) &
    SAMPLER=$!
    rm -f "$K6_CSV"
    set +e
    "${TASKSET[@]}" k6 run --quiet \
       -e TARGET="$TARGET" -e FRAMEWORK="$FRAMEWORK" -e ENDPOINT="$ENDPOINT" \
       -e CONNS="$C" -e THINK_S="$THINK_S" \
       -e RAMP_S="$RAMP_S" -e HOLD_S="$HOLD_S" -e MEASURE_S="$MEASURE_S" \
       "$(dirname "$0")/S9_longconn.js"
    K6_EXIT=$?
    set -e
    [[ $K6_EXIT -ne 0 ]] && echo "note: k6 exit=$K6_EXIT (threshold breach or error) — row still recorded"

    if [[ -f "$K6_CSV" ]]; then
      ROW=$(tail -n1 "$K6_CSV")
      IFS=, read -r _f _c P50 P95 P99 ERR CONN_MEAN CONN_MAX REQS ARPS MAXVU <<< "$ROW"
    else
      echo "WARNING: $K6_CSV missing — k6 produced no summary" >&2
      P50=NaN; P95=NaN; P99=NaN; ERR=NaN; CONN_MEAN=NaN; CONN_MAX=NaN; REQS=NaN; ARPS=NaN; MAXVU=NaN
    fi
  fi

  wait "$SAMPLER" 2>/dev/null || true
  EST=$(cat "$EST_FILE" 2>/dev/null || echo NaN); rm -f "$EST_FILE"

  W_END=$((T0 + RUN_S))
  echo "measured window: $(date -d @$((W_END - MEASURE_S)) +%H:%M:%S) -> $(date -d @${W_END} +%H:%M:%S)"

  echo "waiting ${COOLDOWN}s for Prometheus to ingest the window tail..."
  sleep "$COOLDOWN"

  # A Prometheus restart mid-window silently truncates the series it serves,
  # so flag it rather than reporting a quietly-wrong average.
  PROM_POD_NOW=$(kubectl -n "$NS" get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$PROM_POD_START" && "$PROM_POD_NOW" != "$PROM_POD_START" ]]; then
    echo "  WARNING: prometheus pod changed during this run ($PROM_POD_START -> $PROM_POD_NOW);" >&2
    echo "           CPU/memory for this run may be incomplete." >&2
  fi

  SEL="namespace=\"$NS\",pod=\"$POD\",container!=\"\""
  MEM_AVG=$(pq_at "avg_over_time(container_memory_working_set_bytes{$SEL}[${MEASURE_S}s])" "$W_END" 1048576)
  MEM_MAX=$(pq_at "max_over_time(container_memory_working_set_bytes{$SEL}[${MEASURE_S}s])" "$W_END" 1048576)
  CPU_AVG=$(pq_at "avg_over_time(rate(container_cpu_usage_seconds_total{$SEL}[1m])[${MEASURE_S}s:5s])" "$W_END")
  CPU_MAX=$(pq_at "max_over_time(rate(container_cpu_usage_seconds_total{$SEL}[1m])[${MEASURE_S}s:5s])" "$W_END")

  # A framework that silently refuses connections above some cap shows a flat
  # memory curve that looks like efficiency; the kernel's socket count is the
  # check that distinguishes the two.
  if [[ "$C" -ne 0 && "$EST" != "NaN" ]]; then
    awk -v e="$EST" -v c="$C" 'BEGIN { if (e+0 < c*0.98)
      printf "  WARNING: only %d of %d connections were ESTABLISHED on the host - client or server cap.\n", e, c > "/dev/stderr" }'
  fi
  awk -v m="$CONN_MEAN" 'BEGIN { if (m != "NaN" && m+0 > 0.01)
    print "  WARNING: mean connecting " m " ms - connections are being re-established, not held." > "/dev/stderr" }'

  echo "$FRAMEWORK,$C,$i,$P50,$P95,$P99,$ERR,$CONN_MEAN,$CONN_MAX,$REQS,$ARPS,$MAXVU,$EST,$CPU_AVG,$CPU_MAX,$MEM_AVG,$MEM_MAX,$POD,$K6_EXIT" | tee -a "$OUT"
done
done

echo
echo "Wrote $OUT (environment recorded in $ENV_OUT). Next:"
echo "  python3 S5_stats.py $OUT --group conns --value mem_avg_mib"
echo "  python3 S5_stats.py $OUT --group conns --value cpu_avg_cores"
echo "  # per-connection cost = slope of mem_avg_mib over conns, baseline at conns=0"
