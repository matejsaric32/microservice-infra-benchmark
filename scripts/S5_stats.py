#!/usr/bin/env python3
"""S5 - Statistics pass (Reviewer 1, point 7).
Computes mean, SD, and 95% CI (t-distribution) per framework from raw run CSVs.
Usage: python3 S5_stats.py results.csv --group framework --value startup_s
Output: table ready to paste into Tables 2/4 (mean +/- SD, 95% CI).
Also runs pairwise Mann-Whitney U tests against the fastest framework.
"""
import argparse, csv, math, sys
from collections import defaultdict

try:
    from scipy import stats as sps
    HAVE_SCIPY = True
except ImportError:
    HAVE_SCIPY = False

T95 = {2:12.71,3:4.30,4:3.18,5:2.78,6:2.57,7:2.45,8:2.36,9:2.31,10:2.26,11:2.23,15:2.14,20:2.09,30:2.05}

def t_crit(n):
    if n-1 in T95: return T95[n-1]
    return 1.96 if n > 30 else T95[min(T95, key=lambda k: abs(k-(n-1)))]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvfile"); ap.add_argument("--group", required=True); ap.add_argument("--value", required=True)
    a = ap.parse_args()
    groups = defaultdict(list)
    for row in csv.DictReader(open(a.csvfile)):
        try: groups[row[a.group]].append(float(row[a.value]))
        except (ValueError, KeyError): pass
    if not groups: sys.exit("No data parsed - check column names.")

    print(f"{'framework':<45}{'n':>3}{'mean':>10}{'sd':>9}{'95% CI':>22}")
    summary = {}
    for g, v in sorted(groups.items(), key=lambda kv: sum(kv[1])/len(kv[1])):
        n = len(v); m = sum(v)/n
        sd = math.sqrt(sum((x-m)**2 for x in v)/(n-1)) if n > 1 else 0.0
        h = t_crit(n)*sd/math.sqrt(n) if n > 1 else 0.0
        summary[g] = v
        print(f"{g:<45}{n:>3}{m:>10.3f}{sd:>9.3f}   [{m-h:>7.3f}, {m+h:>7.3f}]")

    if HAVE_SCIPY and len(summary) > 1:
        best = min(summary, key=lambda g: sum(summary[g])/len(summary[g]))
        print(f"\nMann-Whitney U vs fastest ({best}):")
        for g, v in summary.items():
            if g == best: continue
            u, p = sps.mannwhitneyu(summary[best], v, alternative="two-sided")
            print(f"  {g:<43} U={u:.1f}  p={p:.4f}{'  *' if p < 0.05 else ''}")
    elif not HAVE_SCIPY:
        print("\n(install scipy for Mann-Whitney U tests: pip install scipy)")

if __name__ == "__main__":
    main()
