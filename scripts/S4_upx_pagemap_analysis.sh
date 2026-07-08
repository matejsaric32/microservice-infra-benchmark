#!/usr/bin/env bash
# S4 — UPX page-sharing evidence (Reviewer 1 point 6; Reviewer 2 points 1-2)
# Compares memory mappings of an uncompressed vs UPX-compressed Quarkus Native
# binary, and shows how per-replica memory scales with replica count.
# Run on the K3s node. Requires: kubectl, jq, sudo (crictl + /proc access).
set -euo pipefail

NS="${NS:-perf-test}"
REPLICAS="${REPLICAS:-1 3 5 10}"
PROM="${PROM:-http://localhost:9090}"

analyze_pod_maps() { # $1 = pod name -> prints file-backed vs anonymous breakdown
  local POD=$1
  local CID HOSTPID
  CID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  HOSTPID=$(sudo crictl inspect "$CID" | jq -r '.info.pid')
  echo "--- $POD (host pid $HOSTPID) ---"
  echo "smaps_rollup:"
  sudo grep -E '^(Rss|Pss|Shared_Clean|Shared_Dirty|Private_Clean|Private_Dirty|Anonymous):' \
    /proc/"$HOSTPID"/smaps_rollup | sed 's/^/  /'
  echo "executable mappings (r-xp):"
  sudo awk '$2 ~ /r-xp/ {sz=strtonum("0x" substr($1,index($1,"-")+1)) - strtonum("0x" $1); tot+=sz; file=($6!="")?f+1:f; print "  ", $6=="" ? "[anonymous]" : $6, sz/1048576 " MiB"} END {print "  TOTAL r-xp:", tot/1048576, "MiB"}' \
    /proc/"$HOSTPID"/maps
  echo "anonymous vs file-backed (all mappings):"
  sudo awk '{sz=strtonum("0x" substr($1,index($1,"-")+1)) - strtonum("0x" $1); if($6=="") anon+=sz; else fb+=sz} END {printf "  anonymous: %.1f MiB   file-backed: %.1f MiB\n", anon/1048576, fb/1048576}' \
    /proc/"$HOSTPID"/maps
}

for VARIANT in quarkus-perf-native quarkus-perf-native-micro-compressed; do
  echo "==================== $VARIANT ===================="
  for R in $REPLICAS; do
    kubectl -n "$NS" scale deploy "$VARIANT" --replicas="$R"
    kubectl -n "$NS" rollout status deploy/"$VARIANT" --timeout=300s
    sleep 60  # settle
    echo ">>> replicas=$R"
    # node-level total for this deployment (sums across replicas)
    curl -sG "$PROM/api/v1/query" \
      --data-urlencode "query=sum(container_memory_working_set_bytes{pod=~\"$VARIANT.*\",container!=\"\"})" \
      | jq -r '.data.result[0].value[1]' | awk '{printf "  TOTAL working set: %.1f MiB  (per replica: %.1f MiB)\n", $1/1048576, $1/1048576/'$R'}'
    # detailed maps for the first pod only
    POD=$(kubectl -n "$NS" get pod -l app="$VARIANT" -o jsonpath='{.items[0].metadata.name}')
    analyze_pod_maps "$POD"
  done
  kubectl -n "$NS" scale deploy "$VARIANT" --replicas=1
done

# Interpretation guide:
# - Uncompressed binary: large file-backed r-xp mapping of the ELF binary;
#   high Shared_Clean in smaps_rollup; TOTAL working set grows sub-linearly
#   with replica count (kernel shares code pages across replicas).
# - UPX binary: executable lives in anonymous mappings (no file path);
#   Private_Dirty/Anonymous dominates; TOTAL working set grows ~linearly
#   with replica count (no page sharing possible).
# Put smaps_rollup numbers (Shared_Clean vs Private_Dirty) and the
# per-replica scaling into the paper as Table/Figure evidence for H3.
