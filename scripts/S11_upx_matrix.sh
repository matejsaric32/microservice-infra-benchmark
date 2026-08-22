#!/usr/bin/env bash
# S8_upx_matrix.sh — compression x base-image control experiment (Table 8a).
#
# Companion to S4_upx_pagemap_analysis.sh; reuses its pod-discovery and host-PID
# resolution verbatim, because those parts are already correct. Three things
# differ, all of them fixes to problems that make the published Table 8 data
# unusable as a control:
#
#  1. OUTER LOOP OVER VARIANTS. Table 8 compared quarkus-perf-native (UBI
#     minimal, uncompressed) with quarkus-perf-micro-compressed (micro,
#     compressed), which differ in TWO factors at once, so the memory inflation
#     cannot be attributed to compression. Here base image and compression are
#     swept independently.
#
#  2. EVERY POD IS SAMPLED, not just PODS[0]. S4 recorded smaps for the first
#     pod only.
#
#  3. THE AGGREGATE IS MEASURED, NOT INFERRED. In s4_scaling.csv total_ws_mib is
#     NaN for the compressed variant at 3/5/10 replicas and a constant 40.09 for
#     the uncompressed one -- identical to two decimals across three different
#     replica counts, which is not a plausible measurement of a growing
#     population. Section 5.2's "sub-linearly ... but linearly for the
#     compressed variant" claim rests on that column.
#
#     The fix is to stop relying on a single Prometheus query. Summing Pss over
#     all replicas is the correct measurement: PSS charges each shared page once,
#     split across its sharers, so the sum over all sharers is exactly the total
#     physical memory the replica set occupies. That is precisely the quantity
#     the sub-linear/linear claim is about, it comes from the kernel rather than
#     from cAdvisor, and it cannot silently return one pod's value.
#
#     Prometheus is still queried, for continuity with the published column, but
#     the series COUNT is asserted against the replica count and recorded, so a
#     short scrape can no longer masquerade as a measurement.
#
# Run on the K3s node. Requires: kubectl, jq, curl, sudo (crictl + /proc access).
#
# usage:
#   bash scripts/S8_upx_matrix.sh | tee s8_output.txt
#
# env overrides:
#   NS=perf-test  REPLICAS="1 3 5 10"  REPS=1  SETTLE=60
#   PROM=http://localhost:9090        # kubectl -n perf-test port-forward svc/prometheus 9090:9090
#   VARIANTS="quarkus-perf-mx-micro-c0 quarkus-perf-mx-micro-cbest"
#   SKIP_CAPACITY_CHECK=1
set -euo pipefail

NS="${NS:-perf-test}"
REPLICAS="${REPLICAS:-1 3 5 10}"
REPS="${REPS:-1}"
PROM="${PROM:-http://localhost:9090}"
SETTLE="${SETTLE:-60}"
PREFIX="${PREFIX:-quarkus-perf-mx}"
POD_CSV="${POD_CSV:-table8a_pods.csv}"
SUM_CSV="${SUM_CSV:-table8a_summary.csv}"

DEFAULT_VARIANTS=""
for b in ubi micro distroless; do
  for c in c0 c9 cbest clzma; do DEFAULT_VARIANTS+="${PREFIX}-${b}-${c} "; done
done
VARIANTS="${VARIANTS:-$DEFAULT_VARIANTS}"

# --- borrowed verbatim from S4 -------------------------------------------
pods_of_deploy() { # $1 = deployment -> Ready pod names
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

host_pid_of_pod() { # $1 = pod -> host PID
  local pod=$1 cid
  cid=$(kubectl -n "$NS" get pod "$pod" \
        -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
  [[ -n "$cid" ]] || { echo ""; return 1; }
  sudo crictl inspect "$cid" | jq -r '.info.pid'
}

cpu_to_millis() { local v=$1; [[ "$v" == *m ]] && { echo "${v%m}"; return; }; awk -v x="$v" 'BEGIN{printf "%d", x*1000}'; }

allocatable_cpu_millis() { # Ready nodes only: a NotReady node cannot host pods.
  local total=0 c
  while read -r c; do total=$(( total + $(cpu_to_millis "$c") )); done < <(
    kubectl get nodes -o json | jq -r '
      .items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))
      | .status.allocatable.cpu')
  echo "$total"
}

pod_cpu_request_millis() {
  local r
  r=$(kubectl -n "$NS" get deploy "$1" \
      -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
  [[ -n "$r" ]] || { echo 0; return; }
  cpu_to_millis "$r"
}

capacity_ok() {
  [[ "${SKIP_CAPACITY_CHECK:-0}" == "1" ]] && return 0
  local per alloc need
  per=$(pod_cpu_request_millis "$1"); alloc=$(allocatable_cpu_millis)
  need=$(( per * $2 ))
  if (( need > alloc )); then
    echo "  !! SKIP replicas=$2: needs ${need}m CPU of requests, Ready-node allocatable is ${alloc}m."
    return 1
  fi
  return 0
}

rollup_field() { # $1 = pid, $2 = field -> MiB
  sudo awk -v f="^$2:" '$0 ~ f { printf "%.2f", $2/1024; found=1 } END { if (!found) print "NaN" }' \
    /proc/"$1"/smaps_rollup 2>/dev/null || echo "NaN"
}

exec_mappings() { # $1 = pid -> "file_backed_mib anon_mib"
  sudo awk '
    $2 ~ /r-xp/ {
      split($1, a, "-"); sz = strtonum("0x" a[2]) - strtonum("0x" a[1])
      if ($6 == "") anon += sz; else fb += sz
    }
    END { printf "%.2f %.2f", fb/1048576, anon/1048576 }' /proc/"$1"/maps 2>/dev/null \
    || echo "NaN NaN"
}

# --- Prometheus, with the series count returned alongside the sum ----------
prom_ws() { # $@ = pods -> "total_mib distinct_pod_count"
  local re out sum cnt
  re=$(printf '%s|' "$@"); re=${re%|}
  # `max by (pod, container)` collapses duplicate series BEFORE summing.
  #
  # This is not defensive padding. If two node objects resolve to the same
  # kubelet -- e.g. a stale NotReady node left registered alongside its
  # replacement, both on the same host IP -- Prometheus scrapes that one cAdvisor
  # twice and emits two identical series per container, distinguished only by
  # `instance`/`node`. A bare sum() then reports exactly double the true
  # aggregate, silently. Verify with:
  #   count by (instance) (container_memory_working_set_bytes{namespace="perf-test"})
  # and delete any stale node before trusting the raw sum.
  out=$(curl -sfG "$PROM/api/v1/query" \
      --data-urlencode "query=max by (pod, container) (container_memory_working_set_bytes{namespace=\"$NS\",pod=~\"$re\",container!=\"\"})" \
      2>/dev/null) || { echo "NaN 0"; return; }
  cnt=$(jq -r '[.data.result[].metric.pod] | unique | length' <<<"$out" 2>/dev/null || echo 0)
  [[ "$cnt" == "0" ]] && { echo "NaN 0"; return; }
  sum=$(jq -r '[.data.result[].value[1] | tonumber] | add' <<<"$out" \
        | awk '{printf "%.2f", $1/1048576}')
  echo "$sum $cnt"
}

image_of_deploy() {
  kubectl -n "$NS" get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
main() {
  command -v jq >/dev/null || { echo "jq not found"; exit 1; }
  curl -sf "$PROM/-/ready" >/dev/null 2>&1 \
    || echo "WARNING: Prometheus not answering at $PROM. Sum-of-PSS is unaffected; the prom_* columns will be NaN."
    
  echo "=== environment (record these in the manuscript) ==="
  echo "  THP                 : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo unknown)"
  echo "  Ready nodes         : $(kubectl get nodes -o json | jq -r '[.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length')"
  kubectl get nodes --no-headers 2>/dev/null | sed 's/^/    /'
  echo "  settle              : ${SETTLE}s"
  echo "  repetitions         : ${REPS}"
  NOTREADY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}')
  if [[ -n "$NOTREADY" ]]; then
    echo
    echo "  !! NotReady node(s) still registered: $NOTREADY"
    echo "     If such a node shares a host IP with a Ready one, Prometheus scrapes the same"
    echo "     cAdvisor twice and every sum() over container metrics is doubled. Check with:"
    echo "       count by (instance) (container_memory_working_set_bytes{namespace=\"$NS\"})"
    echo "     and remove it:  kubectl delete node <name>"
    echo "     Sum-of-PSS is read from /proc and is unaffected either way."
  fi
  echo

  echo "variant,base,compression,replicas,rep,pod,pss_mib,rss_mib,shared_clean_mib,private_dirty_mib,file_backed_exec_mib,anon_exec_mib" > "$POD_CSV"
  echo "variant,base,compression,image,replicas,rep,n_pods,sum_pss_mib,mean_pss_mib,mean_rss_mib,mean_shared_clean_mib,mean_private_dirty_mib,mean_file_backed_exec_mib,prom_ws_mib,prom_series,prom_series_ok" > "$SUM_CSV"

  for VARIANT in $VARIANTS; do
    BASE="${VARIANT#${PREFIX}-}"; COMP="${BASE##*-}"; BASE="${BASE%-*}"
    echo "==================== $VARIANT (base=$BASE comp=$COMP) ===================="
    if ! kubectl -n "$NS" get deploy "$VARIANT" >/dev/null 2>&1; then
      echo "  !! deployment not found in $NS — apply frameworks/quarkus/native/matrix/ first. Skipping."
      continue
    fi
    IMG=$(image_of_deploy "$VARIANT")

    for R in $REPLICAS; do
      capacity_ok "$VARIANT" "$R" || continue
      for REP in $(seq 1 "$REPS"); do

        # Scale to zero and wait for deletion first, so no page cache or pod
        # from the previous replica count survives into this measurement.
        kubectl -n "$NS" scale deploy "$VARIANT" --replicas=0 >/dev/null
        kubectl -n "$NS" wait --for=delete pod -l app="$VARIANT" --timeout=120s >/dev/null 2>&1 || true

        kubectl -n "$NS" scale deploy "$VARIANT" --replicas="$R" >/dev/null
        if ! kubectl -n "$NS" rollout status deploy/"$VARIANT" --timeout=300s >/dev/null; then
          echo "  !! rollout failed at replicas=$R rep=$REP"
          kubectl -n "$NS" get pod -l app="$VARIANT" --no-headers | sed 's/^/     /'
          continue
        fi

        echo ">>> replicas=$R rep=$REP  (settling ${SETTLE}s)"
        sleep "$SETTLE"

        mapfile -t PODS < <(pods_of_deploy "$VARIANT")
        if (( ${#PODS[@]} == 0 )); then echo "  !! no Ready pods"; continue; fi
        if (( ${#PODS[@]} != R )); then
          echo "  !! WARNING: ${#PODS[@]} Ready pods but replicas=$R"
        fi

        SUM_PSS=0; SUM_RSS=0; SUM_SHC=0; SUM_PVD=0; SUM_FBE=0; N=0
        for POD in "${PODS[@]}"; do
          PID=$(host_pid_of_pod "$POD" 2>/dev/null || echo "")
          if [[ -z "$PID" || "$PID" == "null" ]]; then
            echo "  !! could not resolve host pid for $POD"; continue
          fi
          PSS=$(rollup_field "$PID" Pss)
          RSS=$(rollup_field "$PID" Rss)
          SHC=$(rollup_field "$PID" Shared_Clean)
          PVD=$(rollup_field "$PID" Private_Dirty)
          read -r FBE ANE <<<"$(exec_mappings "$PID")"

          echo "$VARIANT,$BASE,$COMP,$R,$REP,$POD,$PSS,$RSS,$SHC,$PVD,$FBE,$ANE" >> "$POD_CSV"

          # Skip any pod whose smaps could not be read rather than poisoning the
          # aggregate with NaN.
          [[ "$PSS" == "NaN" ]] && continue
          SUM_PSS=$(awk -v a="$SUM_PSS" -v b="$PSS" 'BEGIN{printf "%.2f", a+b}')
          SUM_RSS=$(awk -v a="$SUM_RSS" -v b="$RSS" 'BEGIN{printf "%.2f", a+b}')
          SUM_SHC=$(awk -v a="$SUM_SHC" -v b="$SHC" 'BEGIN{printf "%.2f", a+b}')
          SUM_PVD=$(awk -v a="$SUM_PVD" -v b="$PVD" 'BEGIN{printf "%.2f", a+b}')
          SUM_FBE=$(awk -v a="$SUM_FBE" -v b="$FBE" 'BEGIN{printf "%.2f", a+b}')
          N=$((N+1))
        done

        if (( N == 0 )); then echo "  !! no readable pods at replicas=$R"; continue; fi
        MEAN() { awk -v s="$1" -v n="$N" 'BEGIN{printf "%.2f", s/n}'; }
        M_PSS=$(MEAN "$SUM_PSS"); M_RSS=$(MEAN "$SUM_RSS")
        M_SHC=$(MEAN "$SUM_SHC"); M_PVD=$(MEAN "$SUM_PVD"); M_FBE=$(MEAN "$SUM_FBE")

        read -r PROM_WS PROM_N <<<"$(prom_ws "${PODS[@]}")"
        if [[ "$PROM_N" == "$R" ]]; then PROM_OK=yes; else PROM_OK="NO(${PROM_N}/${R})"; fi

        echo "  n=$N  sum_pss=${SUM_PSS} MiB  mean_pss=${M_PSS}  mean_shared_clean=${M_SHC}  mean_private_dirty=${M_PVD}"
        echo "  prometheus working set=${PROM_WS} MiB from ${PROM_N} series (expected ${R}) -> ${PROM_OK}"

        echo "$VARIANT,$BASE,$COMP,$IMG,$R,$REP,$N,$SUM_PSS,$M_PSS,$M_RSS,$M_SHC,$M_PVD,$M_FBE,$PROM_WS,$PROM_N,$PROM_OK" >> "$SUM_CSV"
      done
    done

    kubectl -n "$NS" scale deploy "$VARIANT" --replicas=0 >/dev/null
  done

  echo
  echo "=== summary ($SUM_CSV) ==="
  column -s, -t < "$SUM_CSV"
  echo
  echo "per-pod detail: $POD_CSV"
}

main "$@"
