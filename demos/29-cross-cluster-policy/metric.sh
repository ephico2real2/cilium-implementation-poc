#!/usr/bin/env bash
# metric.sh [namespace] — hubble_policy_verdicts_total for a namespace from poc1's Prometheus, which holds BOTH clusters'
# series (poc2 remote-writes with the external label cluster=poc2, demo 22). One line per (cluster, action, source → destination
# namespace): the E9 proof is a cluster=poc2 line for a policy applied in poc2.
set -uo pipefail; cd "$(dirname "$0")/../.."; NS="${1:-mesh-lab}"
kubectl --context kind-poc1 -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 29090:9090 >/dev/null 2>&1 & PF=$!; trap 'kill $PF 2>/dev/null' EXIT; sleep 2
curl -s http://127.0.0.1:29090/api/v1/query --data-urlencode "query=sum by (cluster, action, source_namespace, destination_namespace) (hubble_policy_verdicts_total{source_namespace=\"$NS\"} or hubble_policy_verdicts_total{destination_namespace=\"$NS\"})" | python3 -c '
import json,sys
rows=json.load(sys.stdin)["data"]["result"]
print(f"{"cluster":8}{"action":10}{"source_namespace":18}{"destination_namespace":23}verdicts")
for r in sorted(rows, key=lambda r: (r["metric"].get("cluster",""), r["metric"].get("action",""))):
    m=r["metric"]; print(f"{m.get("cluster","-"):8}{m.get("action","-"):10}{m.get("source_namespace","-"):18}{m.get("destination_namespace","-"):23}{r["value"][1]}")
'
