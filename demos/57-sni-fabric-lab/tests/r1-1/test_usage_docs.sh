#!/usr/bin/env bash
# Usage: test_usage_docs.sh <usage.md> <envoy.yaml> <collector config>
# The doc's span count and ports must match what the code sends and what Envoy routes.
set -u
bad=0
if grep -q 'Five synthetic spans' "$1"; then echo "usage.md: phase6 sends 5 traces = 10 spans (measured 10 -> 20), not five spans"; bad=1; fi
if grep -q '4317' "$1" && ! grep -q 'port_value: 4317' "$2"; then echo "usage.md: names gRPC 4317 as reachable, but no Envoy cluster targets 4317"; bad=1; fi
if grep -q '4317' "$3" && ! grep -q 'port_value: 4317' "$2"; then echo "collector: listens on 4317 that no Envoy cluster targets"; bad=1; fi
echo "doc mismatches: ${bad}"; exit "${bad}"
