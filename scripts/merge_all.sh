#!/usr/bin/env bash
# Merge every arm's per-framework/per-level CSVs into one combined CSV per arm:
#
#   merged/compute_all.csv    <- compute/<rps>/s8_compute_metrics_<fw>.csv
#   merged/io_all.csv         <- ioRerunr/<rps>/s7_load_metrics_<fw>.csv
#   merged/longconn_all.csv   <- longconn/<fw>/s10_longconn_<fw>.csv
#
# Companion to merge_io.sh, which splits the io arm per framework; this one goes
# the other way — everything in a single file per arm, ready for S5_stats.py or
# a plotting script.
#
# Re-runnable: each output is rebuilt from scratch, so running it again after
# more sweeps finish simply picks them up.
#
# Every row already carries its own framework and level (rps or conns), so the
# merge is a concatenation — but the level in the row is cross-checked against
# the directory it came from, because a row whose rps column disagrees with its
# directory means a sweep was launched with the wrong environment and would
# quietly land in the wrong group.
set -euo pipefail
cd "$(dirname "$0")"

OUTDIR="${OUTDIR:-merged}"
LEVELS="${LEVELS:-100 500 1000 2000}"
mkdir -p "$OUTDIR"

H_COMPUTE="framework,run,rps,iterations,p50_ms,p95_ms,p99_ms,err_pct,achieved_rps,srv_p50_ms,srv_p95_ms,cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit"
H_IO="framework,run,rps,p50_ms,p95_ms,p99_ms,err_pct,achieved_rps,cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit"
H_LONGCONN="framework,conns,run,p50_ms,p95_ms,p99_ms,err_pct,mean_conn_ms,max_conn_ms,measured_reqs,achieved_rps,max_vus,est_conns_host,cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit"

strip_header() { awk 'NR==1 && /^framework,/ {next} /^[[:space:]]*$/ {next} {print}' "$1"; }

# $1 = arm dir, $2 = file prefix, $3 = header, $4 = out
merge_by_level() {
  local dir="$1" prefix="$2" header="$3" out="$OUTDIR/$4"
  echo "$header" > "$out"
  local l src
  for l in $LEVELS; do
    for src in "$dir/$l/${prefix}"*.csv; do
      [[ -f "$src" ]] || continue
      # column 3 is rps in both the S7 and S8 layouts
      awk -F, -v lvl="$l" -v f="$src" 'NR>1 && $3 != "" && $3 != lvl {
        printf "  WARNING: %s row %d has rps=%s but sits in %s/\n", f, NR, $3, lvl > "/dev/stderr" }' "$src"
      strip_header "$src"
    done
  done | sort -t, -k3,3n -k1,1 -k2,2n >> "$out"
  printf "  %-24s %4s rows  (%s frameworks x %s levels)\n" "$4" \
    "$(tail -n +2 "$out" | grep -c . || true)" \
    "$(tail -n +2 "$out" | cut -d, -f1 | sort -u | grep -c . || true)" \
    "$(tail -n +2 "$out" | cut -d, -f3 | sort -u | grep -c . || true)"
}

merge_by_level compute  s8_compute_metrics_ "$H_COMPUTE" compute_all.csv
merge_by_level ioRerunr s7_load_metrics_    "$H_IO"      io_all.csv

# longconn is laid out per framework rather than per level; the level lives in
# column 2 (conns) instead of column 3 (rps).
out="$OUTDIR/longconn_all.csv"
echo "$H_LONGCONN" > "$out"
for src in longconn/*/s10_longconn_*.csv; do
  [[ -f "$src" ]] || continue
  strip_header "$src"
done | sort -t, -k2,2n -k1,1 -k3,3n >> "$out"
printf "  %-24s %4s rows  (%s frameworks x %s levels)\n" "longconn_all.csv" \
  "$(tail -n +2 "$out" | grep -c . || true)" \
  "$(tail -n +2 "$out" | cut -d, -f1 | sort -u | grep -c . || true)" \
  "$(tail -n +2 "$out" | cut -d, -f2 | sort -u | grep -c . || true)"

# Rows whose Prometheus columns are NaN are present but carry no resource data:
# k6 succeeded and the server-side metrics did not. They must be reported
# separately from missing rows, because the coverage matrix below counts them as
# present and would otherwise imply the arm is complete when it is not.
echo
echo "rows with NaN resource columns (k6 ok, Prometheus returned nothing):"
nan_found=0
for f in compute_all.csv io_all.csv longconn_all.csv; do
  n=$(grep -c "NaN" "$OUTDIR/$f" || true)
  if [[ "$n" != "0" ]]; then
    nan_found=1
    printf "  %-24s %4s rows -- affected frameworks: %s\n" "$f" "$n" \
      "$(grep "NaN" "$OUTDIR/$f" | cut -d, -f1 | sort -u | tr '\n' ' ')"
  fi
done
[[ $nan_found -eq 0 ]] && echo "  none"

# Coverage matrix: an arm missing a framework/level combination is far easier to
# spot here than in a 400-row CSV.
echo
echo "coverage (rows per framework x level):"
for spec in "compute_all.csv 3" "io_all.csv 3" "longconn_all.csv 2"; do
  set -- $spec
  echo "  --- $1 ---"
  tail -n +2 "$OUTDIR/$1" | awk -F, -v lc="$2" '{k=$1 FS $lc; n[k]++; fw[$1]; lv[$lc]}
    END { printf "    %-26s", "framework";
          m=asorti(lv, sl, "@val_num_asc");
          for (i=1;i<=m;i++) printf "%8s", sl[i]; print "";
          p=asorti(fw, sf); for (j=1;j<=p;j++) { printf "    %-26s", sf[j];
            for (i=1;i<=m;i++) printf "%8s", (n[sf[j] FS sl[i]] ? n[sf[j] FS sl[i]] : "-"); print "" } }'
done
