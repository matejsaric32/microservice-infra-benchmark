#!/usr/bin/env bash
# S4 — UPX page-sharing evidence (Reviewer 1 point 6; Reviewer 2 points 1-2)
#
# Compares memory mappings of an uncompressed vs UPX-compressed Quarkus Native
# binary, and shows how per-replica memory scales with replica count.
#
# Run on the K3s node. Requires: kubectl, jq, curl, sudo (crictl + /proc access).
#
# Usage:
#   ./S4_upx_pagemap_analysis.sh | tee s4_output.txt
#
# Env overrides:
#   NS=perf-test  REPLICAS="1 3 5 10"  PROM=http://localhost:9090
#   VARIANTS="quarkus-perf-native quarkus-perf-micro-compressed"
#   SETTLE=60                 # seconds to settle after each scale
#   SKIP_CAPACITY_CHECK=1     # bypass the node-capacity preflight
set -euo pipefail

NS="${NS:-perf-test}"
REPLICAS="${REPLICAS:-1 3 5 10}"
PROM="${PROM:-http://localhost:9090}"
VARIANTS="${VARIANTS:-quarkus-perf-native quarkus-perf-micro-compressed}"
SETTLE="${SETTLE:-60}"
CSV="${CSV:-s4_scaling.csv}"

# ---------------------------------------------------------------------------
# Pod discovery.
#
# We deliberately do NOT use `-l app=<deployment>`. Your manifests reuse the
# label `app: quarkus-perf` across several native variants, so a label selector
# silently matches the wrong pods. Instead we walk ownerReferences:
#     Deployment -> ReplicaSet -> Pod
# which is exact regardless of what labels the manifests carry.
# ---------------------------------------------------------------------------
pods_of_deploy() { # $1 = deployment name -> prints Ready pod names, one per line
  local d=$1 rs
  rs=$(kubectl -n "$NS" get rs -o json \
        | jq -r --arg d "$d" '.items[] | select(.metadata.ownerReferences[]?.name == $d) | .metadata.name')
  [[ -n "$rs" ]] || return 0
  kubectl -n "$NS" get pod -o json | jq -r --arg rs "$rs" '
    ($rs | split("\n") | map(select(length > 0))) as $rslist
    | .items[]
    | select(any(.metadata.ownerReferences[]?; .name as $n | $rslist | index($n)))
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name'
}

host_pid_of_pod() { # $1 = pod name -> host PID of its first container
  local pod=$1 cid
  cid=$(kubectl -n "$NS" get pod "$pod" \
        -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  [[ -n "$cid" ]] || { echo "" ; return 1; }
  sudo crictl inspect "$cid" | jq -r '.info.pid'
}


cpu_to_millis() { # "4" -> 4000 ; "3800m" -> 3800
  local v=$1
  [[ "$v" == *m ]] && { echo "${v%m}"; return; }
  awk -v x="$v" 'BEGIN{printf "%d", x*1000}'
}

allocatable_cpu_millis() {
  local total=0 c
  while read -r c; do total=$(( total + $(cpu_to_millis "$c") )); done < <(
    kubectl get nodes -o json | jq -r '.items[].status.allocatable.cpu')
  echo "$total"
}

pod_cpu_request_millis() { # $1 = deployment
  local r
  r=$(kubectl -n "$NS" get deploy "$1" \
      -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
  [[ -n "$r" ]] || { echo 0; return; }
  cpu_to_millis "$r"
}

capacity_ok() { # $1 = deployment, $2 = replica count
  [[ "${SKIP_CAPACITY_CHECK:-0}" == "1" ]] && return 0
  local per alloc need
  per=$(pod_cpu_request_millis "$1"); alloc=$(allocatable_cpu_millis)
  need=$(( per * $2 ))
  if (( need > alloc )); then
    echo "  !! SKIP replicas=$2: needs ${need}m CPU of requests, node allocatable is ${alloc}m."
    echo "     Lower the cpu request in the manifest, or set SKIP_CAPACITY_CHECK=1 to try anyway."
    return 1
  fi
  return 0
}


prom_working_set_mib() { # $@ = pod names -> total working set in MiB
  local re
  re=$(printf '%s|' "$@"); re=${re%|}
  curl -sfG "$PROM/api/v1/query" \
      --data-urlencode "query=sum(container_memory_working_set_bytes{namespace=\"$NS\",pod=~\"$re\",container!=\"\"})" \
    | jq -r '.data.result[0].value[1] // "NaN"' \
    | awk '{ if ($1=="NaN") print "NaN"; else printf "%.2f", $1/1048576 }'
}

rollup_field() { # $1 = host pid, $2 = field  -> MiB
  sudo awk -v f="^$2:" '$0 ~ f { printf "%.2f", $2/1024; found=1 } END { if (!found) print "NaN" }' \
    /proc/"$1"/smaps_rollup 2>/dev/null || echo "NaN"
}

analyze_pod_maps() { # $1 = pod name
  local pod=$1 pid
  pid=$(host_pid_of_pod "$pod") || { echo "  !! could not resolve host pid for $pod"; return 0; }
  [[ -n "$pid" && "$pid" != "null" ]] || { echo "  !! no host pid for $pod"; return 0; }

  echo "  --- $pod (host pid $pid) ---"
  echo "  smaps_rollup (RESIDENT):"
  sudo grep -E '^(Rss|Pss|Shared_Clean|Shared_Dirty|Private_Clean|Private_Dirty|Anonymous):' \
    /proc/"$pid"/smaps_rollup | sed 's/^/    /'

  echo "  executable mappings (r-xp), file-backed vs anonymous:"
  sudo awk '
    $2 ~ /r-xp/ {
      split($1, a, "-")
      sz = strtonum("0x" a[2]) - strtonum("0x" a[1])
      path = ($6 == "" ? "[anonymous]" : $6)
      if ($6 == "") anon += sz; else fb += sz
      tot += sz
      printf "    %-52s %8.3f MiB\n", path, sz/1048576
    }
    END {
      printf "    %-52s %8.3f MiB\n", "TOTAL r-xp", tot/1048576
      printf "    %-52s %8.3f MiB\n", "  of which file-backed", fb/1048576
      printf "    %-52s %8.3f MiB\n", "  of which anonymous",   anon/1048576
    }' /proc/"$pid"/maps

  echo "  all mappings, VIRTUAL address space (not resident — do not quote as footprint):"
  sudo awk '
    { split($1, a, "-"); sz = strtonum("0x" a[2]) - strtonum("0x" a[1])
      if ($6 == "") anon += sz; else fb += sz }
    END { printf "    anonymous: %.1f MiB   file-backed: %.1f MiB\n", anon/1048576, fb/1048576 }' \
    /proc/"$pid"/maps
}

# ---------------------------------------------------------------------------
main() {
  command -v jq >/dev/null || { echo "jq not found"; exit 1; }
  curl -sf "$PROM/-/ready" >/dev/null 2>&1 \
    || echo "WARNING: Prometheus not answering at $PROM — working-set columns will be NaN."

  echo "variant,replicas,total_ws_mib,per_replica_ws_mib,pss_mib,rss_mib,shared_clean_mib,private_dirty_mib" > "$CSV"

  for VARIANT in $VARIANTS; do
    echo "==================== $VARIANT ===================="
    if ! kubectl -n "$NS" get deploy "$VARIANT" >/dev/null 2>&1; then
      echo "  !! deployment not found in namespace $NS — skipping."
      continue
    fi

    for R in $REPLICAS; do
      capacity_ok "$VARIANT" "$R" || continue

      kubectl -n "$NS" scale deploy "$VARIANT" --replicas="$R"
      if ! kubectl -n "$NS" rollout status deploy/"$VARIANT" --timeout=300s; then
        echo "  !! rollout did not complete at replicas=$R. Diagnose with:"
        echo "     kubectl -n $NS get pod -o wide | grep $VARIANT"
        echo "     kubectl -n $NS describe deploy $VARIANT | tail -20"
        continue
      fi

      echo ">>> replicas=$R  (settling ${SETTLE}s)"
      sleep "$SETTLE"

      mapfile -t PODS < <(pods_of_deploy "$VARIANT")
      if (( ${#PODS[@]} == 0 )); then
        echo "  !! no Ready pods found for $VARIANT — skipping."
        continue
      fi
      echo "  pods: ${PODS[*]}"

      TOTAL=$(prom_working_set_mib "${PODS[@]}")
      PER=$(awk -v t="$TOTAL" -v r="$R" 'BEGIN{ if (t=="NaN") print "NaN"; else printf "%.2f", t/r }')
      echo "  TOTAL working set: ${TOTAL} MiB   (per replica: ${PER} MiB)"

      # Detailed maps for the first pod; smaps figures recorded for the CSV.
      PID=$(host_pid_of_pod "${PODS[0]}" || echo "")
      if [[ -n "$PID" && "$PID" != "null" ]]; then
        PSS=$(rollup_field "$PID" Pss)
        RSS=$(rollup_field "$PID" Rss)
        SHC=$(rollup_field "$PID" Shared_Clean)
        PVD=$(rollup_field "$PID" Private_Dirty)
      else
        PSS=NaN; RSS=NaN; SHC=NaN; PVD=NaN
      fi
      echo "$VARIANT,$R,$TOTAL,$PER,$PSS,$RSS,$SHC,$PVD" >> "$CSV"

      analyze_pod_maps "${PODS[0]}"
    done

    kubectl -n "$NS" scale deploy "$VARIANT" --replicas=1 >/dev/null
  done

  echo
  echo "=== Scaling summary ($CSV) ==="
  column -s, -t < "$CSV"
}

main "$@"
