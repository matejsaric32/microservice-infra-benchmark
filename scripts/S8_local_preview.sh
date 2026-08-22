#!/usr/bin/env bash
# S8_local_preview.sh — reproduce the Table 8a page-sharing measurement with
# plain podman on the host, with no cluster, no sudo and no image import.
#
# WHY THIS EXISTS
# The mechanism in section 5.2 is a property of the kernel, not of Kubernetes:
# N processes mmap-ing the same inode share its file-backed pages, so PSS decays
# as 1/N for an uncompressed binary and stays flat for a UPX-packed one that
# unpacks into anonymous memory. Containerd and podman both land on the same
# overlay lower-layer inode, so the effect is identical and can be measured in
# minutes instead of hours.
#
# THESE NUMBERS ARE A PREVIEW, NOT THE PUBLISHED RESULT. They differ from the
# cluster measurement in cgroup limits, in the absence of the ConfigMap/Secret
# environment, and in having no reachable Kafka or PostgreSQL. Use them to
# validate the pipeline and to see the shape of the result before committing to
# the full sweep; use scripts/S8_upx_matrix.sh for the figures that go in the
# paper.
#
# usage:
#   bash scripts/S8_local_preview.sh | tee s8_local_preview.txt
# env:
#   CELLS="micro-c0 micro-cbest ..."   REPLICAS="1 3 5 10"   SETTLE=20
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/matejsaric32}"
PREFIX="${PREFIX:-quarkus-perf-mx}"
REPLICAS="${REPLICAS:-1 3 5 10}"
SETTLE="${SETTLE:-20}"
OUT="${OUT:-table8a_local_preview.csv}"
POD_OUT="${POD_OUT:-table8a_local_preview_pods.csv}"
LABEL="s8preview"

DEFAULT_CELLS=""
for b in micro distroless; do for c in c0 cbest c9 clzma; do DEFAULT_CELLS+="${b}-${c} "; done; done
CELLS="${CELLS:-$DEFAULT_CELLS}"

cleanup() { podman rm -f $(podman ps -aq --filter "label=$LABEL") >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "variant,base,compression,replicas,n,mean_pss_mib,sum_pss_mib,mean_rss_mib,mean_shared_clean_mib,mean_private_dirty_mib,mean_file_backed_exec_mib,mean_anon_exec_mib,image_mib" > "$OUT"
echo "variant,replicas,idx,pid,pss_mib,rss_mib,shared_clean_mib,private_dirty_mib,file_backed_exec_mib,anon_exec_mib" > "$POD_OUT"

for cell in $CELLS; do
  base="${cell%-*}"; comp="${cell##*-}"
  img="$REGISTRY/$PREFIX-$cell:latest"
  if ! podman image exists "$img"; then echo "!! missing image $img — skipping"; continue; fi
  img_mib=$(podman image inspect "$img" --format '{{.Size}}' | awk '{printf "%.2f", $1/1048576}')

  echo "==================== $cell (base=$base comp=$comp, image ${img_mib} MiB) ===================="
  for R in $REPLICAS; do
    cleanup
    ids=()
    for i in $(seq 1 "$R"); do
      ids+=("$(podman run -d --label "$LABEL" --name "${LABEL}-${cell}-${i}" "$img")")
    done
    sleep "$SETTLE"

    SUM_PSS=0; SUM_RSS=0; SUM_SHC=0; SUM_PVD=0; SUM_FBE=0; SUM_ANE=0; N=0
    idx=0
    for id in "${ids[@]}"; do
      idx=$((idx+1))
      pid=$(podman inspect "$id" --format '{{.State.Pid}}' 2>/dev/null || echo 0)
      [[ "$pid" == "0" || ! -r /proc/$pid/smaps_rollup ]] && { echo "  !! pid $pid unreadable"; continue; }
      read -r pss rss shc pvd <<<"$(awk '
        /^Pss:/{p=$2/1024} /^Rss:/{r=$2/1024} /^Shared_Clean:/{s=$2/1024} /^Private_Dirty:/{d=$2/1024}
        END{printf "%.2f %.2f %.2f %.2f", p,r,s,d}' /proc/$pid/smaps_rollup)"
      read -r fbe ane <<<"$(awk '
        $2 ~ /r-xp/ { split($1,a,"-"); sz=strtonum("0x" a[2])-strtonum("0x" a[1]);
                      if ($6=="") an+=sz; else fb+=sz }
        END{printf "%.2f %.2f", fb/1048576, an/1048576}' /proc/$pid/maps)"

      echo "$cell,$R,$idx,$pid,$pss,$rss,$shc,$pvd,$fbe,$ane" >> "$POD_OUT"
      SUM_PSS=$(awk -v a=$SUM_PSS -v b=$pss 'BEGIN{printf "%.2f",a+b}')
      SUM_RSS=$(awk -v a=$SUM_RSS -v b=$rss 'BEGIN{printf "%.2f",a+b}')
      SUM_SHC=$(awk -v a=$SUM_SHC -v b=$shc 'BEGIN{printf "%.2f",a+b}')
      SUM_PVD=$(awk -v a=$SUM_PVD -v b=$pvd 'BEGIN{printf "%.2f",a+b}')
      SUM_FBE=$(awk -v a=$SUM_FBE -v b=$fbe 'BEGIN{printf "%.2f",a+b}')
      SUM_ANE=$(awk -v a=$SUM_ANE -v b=$ane 'BEGIN{printf "%.2f",a+b}')
      N=$((N+1))
    done
    (( N == 0 )) && { echo "  !! no readable replicas at R=$R"; continue; }
    M(){ awk -v s=$1 -v n=$N 'BEGIN{printf "%.2f", s/n}'; }
    printf '  replicas=%-3s n=%-3s mean_pss=%-8s sum_pss=%-9s shared_clean=%-8s private_dirty=%-8s fb_exec=%s\n' \
      "$R" "$N" "$(M $SUM_PSS)" "$SUM_PSS" "$(M $SUM_SHC)" "$(M $SUM_PVD)" "$(M $SUM_FBE)"
    echo "$cell,$base,$comp,$R,$N,$(M $SUM_PSS),$SUM_PSS,$(M $SUM_RSS),$(M $SUM_SHC),$(M $SUM_PVD),$(M $SUM_FBE),$(M $SUM_ANE),$img_mib" >> "$OUT"
  done
  cleanup
done

echo
echo "=== $OUT ==="
column -s, -t < "$OUT"
