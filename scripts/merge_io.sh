#!/usr/bin/env bash
# Merge per-RPS result dirs into one CSV per framework under io/.
# Re-runnable: rebuilds io/ from scratch each time, so adding a new RPS level
# (e.g. a 4000/ dir) only needs LEVELS updated.
set -euo pipefail
cd "$(dirname "$0")"
LEVELS="${LEVELS:-100 500 1000 2000}"
OUTDIR="${OUTDIR:-io}"
HEADER="framework,run,rps,p50_ms,p95_ms,p99_ms,err_pct,achieved_rps,cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit"

mkdir -p "$OUTDIR"
frameworks=$(for l in $LEVELS; do ls "$l"/s7_load_metrics_*.csv 2>/dev/null; done \
             | sed 's|.*/s7_load_metrics_||; s|\.csv$||' | sort -u)

for fw in $frameworks; do
  out="$OUTDIR/${fw}.csv"
  echo "$HEADER" > "$out"
  for l in $LEVELS; do
    src="$l/s7_load_metrics_${fw}.csv"
    [[ -f "$src" ]] || { echo "  note: $src missing" >&2; continue; }
    # Skip a header row if present; some files lost theirs mid-run.
    awk 'NR==1 && /^framework,/ {next} /^[[:space:]]*$/ {next} {print}' "$src"
  done | sort -t, -k3,3n -k2,2n >> "$out"
  printf "  %-26s %s rows\n" "$fw" "$(tail -n +2 "$out" | grep -c .)"
done

# Combined file across every framework: convenient for S5_stats.py and plotting.
all="$OUTDIR/all.csv"
echo "$HEADER" > "$all"
for fw in $frameworks; do tail -n +2 "$OUTDIR/${fw}.csv"; done \
  | sort -t, -k3,3n -k1,1 -k2,2n >> "$all"
printf "  %-26s %s rows\n" "all.csv" "$(tail -n +2 "$all" | grep -c .)"
