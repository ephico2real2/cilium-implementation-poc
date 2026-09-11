#!/usr/bin/env bash
# bench.sh — run N iperf3 samples and compute the statistics, showing every raw number.
#
# Usage:
#   scripts/bench.sh <label> <context> <namespace> <client-pod> <server-target> [runs]
#
# Examples:
#   scripts/bench.sh intra kind-poc1 perf iperf3-client 10.10.4.116
#   scripts/bench.sh cross kind-poc1 perf iperf3-client iperf3-global.perf.svc.cluster.local 5
#
# WHY THIS EXISTS RATHER THAN EYEBALLING IT.
#   1. One run proves nothing. This rig varies by ~25% between identical runs, so a single number
#      is indistinguishable from noise.
#   2. The MEDIAN is used, not the mean, because one stalled run drags a mean badly and medians
#      ignore outliers.
#   3. The SPREAD is printed as prominently as the median, because a difference between two
#      configurations means nothing unless it is larger than the spread within each of them.
#
# Every raw sample is printed. Nothing here is computed off-screen.
set -uo pipefail

LABEL="${1:?usage: bench.sh <label> <context> <ns> <client-pod> <target> [runs]}"
CTX="${2:?}"; NS="${3:?}"; POD="${4:?}"; TARGET="${5:?}"; RUNS="${6:-5}"
DUR="${DUR:-10}"

echo "=== $LABEL ==="
echo "context=$CTX  ns=$NS  client=$POD  target=$TARGET  runs=$RUNS  duration=${DUR}s"
echo

samples=()
for i in $(seq "$RUNS"); do
  v=$(kubectl --context "$CTX" -n "$NS" exec "$POD" -- \
        iperf3 -c "$TARGET" -t "$DUR" -f m 2>/dev/null \
        | awk '/receiver/ {print $7}')
  if [ -z "$v" ]; then
    echo "  run $i: FAILED (no result)"
  else
    echo "  run $i: $v Mbits/sec"
    samples+=("$v")
  fi
done

n=${#samples[@]}
if [ "$n" -eq 0 ]; then echo; echo "no successful runs"; exit 1; fi

echo
printf '%s\n' "${samples[@]}" | python3 -c '
import sys, statistics
xs = sorted(float(l) for l in sys.stdin if l.strip())
n = len(xs)
med, lo, hi = statistics.median(xs), xs[0], xs[-1]
# Spread as a percentage of the median: how much the SAME configuration varies run to run.
spread = (hi - lo) / med * 100 if med else 0
print(f"  samples : {n}")
joined = ", ".join("%.0f" % x for x in xs)
print("  sorted  : " + joined)
print(f"  median  : {med:.0f} Mbits/sec")
print(f"  min/max : {lo:.0f} / {hi:.0f} Mbits/sec")
print(f"  spread  : {spread:.1f}%  of median   <-- treat any difference smaller than this as noise")
'
