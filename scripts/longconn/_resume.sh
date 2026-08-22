#!/usr/bin/env bash
# Resume the longconn arm after the cAdvisor outage of 2026-08-22.
#
#   1. quarkus-native, levels 1000 and 2000 ONLY -> its own CSV. Levels 0/100/500
#      already carry good data in s10_longconn_quarkus-native.csv; re-running them
#      would cost 20 minutes for numbers we already have. merge_all.sh globs
#      s10_longconn_*.csv per framework, so the two files merge on their own.
#   2. quarkus-reactive-jvm, full sweep.
#   3. quarkus-reactive-native, full sweep.
#
# Blocks until the API server can actually proxy to the kubelet. Prometheus stays
# reachable during these outages and answers queries with empty results, so
# "Prometheus is up" is not the condition worth waiting on — this polls the exact
# path the cAdvisor scrape uses, and until it works every resource column is NaN.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> scripts/

REPS="${REPS:-1}"
K6_CPUS="${K6_CPUS:-16-31}"
WAIT_MAX="${WAIT_MAX:-21600}"    # 6 h; the fix needs sudo, so give it a long window

# NOTE: no early-exiting consumers in these pipelines. Under `set -o pipefail`,
# an `awk ... exit` or `grep -q` closes the pipe, kubectl dies of SIGPIPE, and the
# pipeline reports failure even when the data arrived fine — which made this
# function return false forever while the cluster was perfectly healthy.
metrics_ok() {
  local node hits
  node=$(timeout 20 kubectl get nodes --no-headers 2>/dev/null \
         | awk '$2=="Ready"{n=$1} END{print n}')
  [[ -n "$node" ]] || return 1
  hits=$(timeout 30 kubectl get --raw "/api/v1/nodes/${node}/proxy/metrics/cadvisor" 2>/dev/null \
         | grep -c container_memory_working_set_bytes)
  [[ "${hits:-0}" -gt 0 ]]
}

echo "======== LONGCONN RESUME $(date +%H:%M:%S) ========"
waited=0
until metrics_ok; do
  (( waited % 300 == 0 )) && echo "$(date +%H:%M:%S) waiting for cAdvisor to be scrapable (sudo systemctl restart k3s)..."
  (( waited >= WAIT_MAX )) && { echo "gave up after ${WAIT_MAX}s" >&2; exit 1; }
  sleep 30; waited=$(( waited + 30 ))
done
echo "$(date +%H:%M:%S) cAdvisor reachable - starting."

run() { # $1 fw, $2 deploy, $3 port, $4 levels, $5 suffix
  local fw=$1 dep=$2 port=$3 levels=$4 sfx=${5:-}
  local dir="longconn/${fw}"
  mkdir -p "$dir"
  echo
  echo "######## $(date +%H:%M:%S)  ${fw} levels=[${levels}] ${sfx:+(${sfx})}  ########"
  ( cd "$dir" && LEVELS="$levels" K6_CPUS="$K6_CPUS" \
      OUT="s10_longconn_${fw}${sfx}.csv" ENV_OUT="s10_longconn_env_${fw}${sfx}.txt" \
      ../../S10_longconn_with_metrics.sh "$fw" "$dep" "$port" "$REPS" 2>&1 \
      | tee "run${sfx}.log" )
  echo "## finished ${fw}${sfx} at $(date +%H:%M:%S)"
}

run quarkus-native          quarkus-perf-native          31095 "1000 2000"        _lvl1000-2000
run quarkus-reactive-jvm    quarkus-reactive-perf-jvm    31096 "0 100 500 1000 2000"
run quarkus-reactive-native quarkus-reactive-perf-native 31097 "0 100 500 1000 2000"

echo
echo "======== RESUME COMPLETE $(date +%H:%M:%S) ========"
for f in longconn/*/s10_longconn_*.csv; do
  [[ -f "$f" ]] || continue
  printf '  %-58s %2s rows  %s\n' "$f" "$(tail -n +2 "$f" | grep -c .)" \
    "$(grep -c NaN "$f" | sed 's/^0$//; s/^[1-9].*/<-- HAS NaN/')"
done
