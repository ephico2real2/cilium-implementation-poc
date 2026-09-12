#!/usr/bin/env bash
# policy-metric.sh [namespace] — the policy verdicts Hubble counted for a namespace, straight from the hub Prometheus
# (through the API server's service proxy, so no route or port-forward is needed). Feeds the "Network Policy" row of the
# Hubble Metrics dashboard and demo 26's own panels. action=audit only appears while an endpoint is in PolicyAuditMode.
set -uo pipefail; NS="${1:-cf2cnp-lab}"
Q="sum(hubble_policy_verdicts_total{destination_namespace=\"$NS\"}) by (cluster,direction,source,destination,action,match)"
kubectl --context kind-poc1 get --raw "/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$Q")" \
 | python3 -c '
import json,sys; r=json.load(sys.stdin)["data"]["result"]
print("  %-8s %-8s %-10s %-12s %-10s %-6s %s" % ("cluster","dir","source","destination","action","match","count"))
for x in sorted(r, key=lambda x:(x["metric"]["source"],x["metric"]["action"])):
    m=x["metric"]; print("  %-8s %-8s %-10s %-12s %-10s %-6s %s" % (m["cluster"],m["direction"],m["source"],m["destination"],m["action"],m["match"],x["value"][1]))'
