#!/usr/bin/env bash
# S3 — Verify Actix Web idle memory (Reviewer 1, point 5)
# Reports working_set, RSS, PSS, and cgroup total across N repeated deployments.
# Run on the K3s node. Requires: kubectl, curl, jq; Prometheus reachable at $PROM.
set -euo pipefail

DEPLOY="${1:-actix-perf}"            # deployment name
NS="${2:-perf-test}"
MANIFEST="${MANIFEST:-frameworks/rust/actix-deployment.yaml}"  # path in your infra repo
PROM="${PROM:-http://localhost:9090}"
N="${N:-10}"
IDLE_WAIT="${IDLE_WAIT:-120}"        # seconds to settle before sampling
OUT="actix_memory_verify.csv"

echo "run,working_set_mib,rss_mib,cgroup_usage_mib,pss_mib" > "$OUT"

pq() { # prometheus instant query -> MiB
  curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // "NaN"' \
    | awk '{printf "%.2f", $1/1048576}'
}

for i in $(seq 1 "$N"); do
  echo "=== Run $i/$N: cold redeploy ==="
  kubectl -n "$NS" delete deploy "$DEPLOY" --ignore-not-found --wait=true
  sleep 5
  kubectl -n "$NS" apply -f "$MANIFEST"
  kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=300s
  echo "settling ${IDLE_WAIT}s..."
  sleep "$IDLE_WAIT"

  POD=$(kubectl -n "$NS" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}')
  WS=$(pq "container_memory_working_set_bytes{pod=\"$POD\",container!=\"\"}")
  RSS=$(pq "container_memory_rss{pod=\"$POD\",container!=\"\"}")
  USAGE=$(pq "container_memory_usage_bytes{pod=\"$POD\",container!=\"\"}")

  # PSS from inside the container's cgroup namespace (smaps_rollup), via nsenter on the node.
  CID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  HOSTPID=$(sudo crictl inspect "$CID" | jq -r '.info.pid')
  PSS=$(sudo awk '/^Pss:/{print $2/1024}' /proc/"$HOSTPID"/smaps_rollup 2>/dev/null || echo "NaN")

  echo "$i,$WS,$RSS,$USAGE,$PSS" | tee -a "$OUT"
done

echo; echo "=== Summary (mean ± sd) ==="
python3 - "$OUT" <<'EOF'
import csv, statistics as st, sys
rows = list(csv.DictReader(open(sys.argv[1])))
for col in ["working_set_mib","rss_mib","cgroup_usage_mib","pss_mib"]:
    v = [float(r[col]) for r in rows if r[col] not in ("NaN","")]
    if v: print(f"{col}: {st.mean(v):.2f} ± {st.stdev(v) if len(v)>1 else 0:.2f} MiB (n={len(v)})")
EOF
