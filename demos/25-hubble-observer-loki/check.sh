#!/usr/bin/env bash
# check.sh — the demo 25 pipeline, end to end: observer (against the relay), collector (the observer file → Loki), Loki
# (streams with the dashboard's labels, counts by cluster), Grafana (data source + dashboard), cf2cnp (route + health).
# Usage: check.sh [hours, default 1]
set -uo pipefail; H="${1:-1}"; CTX=kind-poc1; cd "$(dirname "$0")/../.."
echo "== observer =="; kubectl --context $CTX -n hubble-observer get pods -o custom-columns='  POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName' --no-headers
echo "  relay as the observer sees it: $(kubectl --context $CTX -n hubble-observer exec deploy/hubble-observer -c hubble-observer -- hubble status --server hubble-relay.kube-system.svc.cluster.local:80 2>/dev/null | grep -E 'Connected Nodes' | tr -s ' ')"
echo "== collector → Loki (per pod: spans of the Loki exporter's queue) =="
for P in $(kubectl --context $CTX -n otel get pods -l app=otel-collector -o name | cut -d/ -f2); do kubectl --context $CTX get --raw "/api/v1/namespaces/otel/pods/$P:8888/proxy/metrics" 2>/dev/null | awk -v p="$P" '/^otelcol_exporter_queue_size\{.*loki/ {q=$NF} /^otelcol_exporter_sent_log_records\{.*loki/ {s=$NF} /^otelcol_exporter_send_failed_log_records\{.*loki/ {f=$NF} END{printf "  %-26s loki queue=%s sent_logs=%s failed=%s\n", p, (q==""?"-":q), (s==""?"0":s), (f==""?"0":f)}'; done
echo "== Loki =="; NOW=$(date +%s)
echo "  index labels: $(kubectl --context $CTX get --raw /api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/labels | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("data",[])))')"
Q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('sum by (flow_source_cluster_name, flow_verdict) (count_over_time({namespace=\"hubble-observer\",container=\"hubble-observer\"} | json | __error__=\"\" [${H}h]))'))")
kubectl --context $CTX get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query?query=$Q&time=$NOW" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print("  stored flows, last '"$H"' h, by source cluster and verdict:"); [print("   ", x["metric"], x["value"][1]) for x in r] if r else print("    none")'
echo "== Grafana =="; GW=$(kubectl --context $CTX -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
curl -s --cacert docs/root-ca.crt --resolve grafana.poc.local:443:$GW -u admin:poc-grafana https://grafana.poc.local/api/datasources | python3 -c 'import json,sys; [print("  ds:", d["name"], d["type"], d["url"]) for d in json.load(sys.stdin) if d["type"]=="loki"]'
curl -s --cacert docs/root-ca.crt --resolve grafana.poc.local:443:$GW -u admin:poc-grafana "https://grafana.poc.local/api/search?query=Hubble%20Observer" | python3 -c 'import json,sys; [print("  dashboard:", d["title"], "| folder:", d.get("folderTitle"), "| /d/"+d["uid"]) for d in json.load(sys.stdin)]'
echo "== cf2cnp =="; kubectl --context $CTX -n routes get httproute cf2cnp -o custom-columns='  ROUTE:.metadata.name,HOSTS:.spec.hostnames,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status' --no-headers
echo "  health: $(curl -s --cacert docs/root-ca.crt --resolve cf2cnp.poc.local:443:$GW https://cf2cnp.poc.local/health)"
