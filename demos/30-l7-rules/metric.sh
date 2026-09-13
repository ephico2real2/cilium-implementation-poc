#!/usr/bin/env bash
# metric.sh [namespace] — what the two Hubble metrics say about the lab, from poc1's Prometheus: the proxy's own decisions
# (hubble_policy_verdicts_total, match=l7/http — E2's rules are decided BY the proxy) and the HTTP status codes the proxy
# reported (hubble_http_requests_total, status=403 is the proxy's answer to a request no rule matched).
set -uo pipefail; cd "$(dirname "$0")/../.."; NS="${1:-cf2cnp-lab30}"
kubectl --context kind-poc1 -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 29090:9090 >/dev/null 2>&1 & PF=$!; trap 'kill $PF 2>/dev/null' EXIT; sleep 2
q() { echo "== $1"; curl -s http://127.0.0.1:29090/api/v1/query --data-urlencode "query=$1" | python3 -c '
import json,sys
for r in sorted(json.load(sys.stdin)["data"]["result"], key=lambda r: json.dumps(r["metric"], sort_keys=True)): print("  ", " ".join(f"{k}={v}" for k,v in sorted(r["metric"].items())), r["value"][1])'; }
q "sum by (action, match) (hubble_policy_verdicts_total{destination_namespace=\"$NS\"})"
q "sum by (status, destination_workload, reporter) (hubble_http_requests_total{destination_namespace=\"$NS\"})"
