#!/usr/bin/env bash
# check.sh — the compatibility page's verification, run against BOTH clusters: every "GET " / "POST " line
# OBI printed (trace_printer: text), i.e. the requests it saw with their trace ids. Usage: check.sh [since]
set -uo pipefail; SINCE="${1:-5m}"
for C in poc1 poc2; do
  echo "== $C =="
  for i in $(kubectl --context kind-$C get pods -n obi -o name | cut -d/ -f2); do
    kubectl --context kind-$C logs -n obi "$i" --since="$SINCE" 2>/dev/null | grep -E "GET |POST " | grep -v "/healthz" | sort   # probes: trace_printer still prints them (Part 2)
  done
done
