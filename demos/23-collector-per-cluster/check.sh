#!/usr/bin/env bash
# check.sh — proves the per-cluster collector standard on both clusters:
#   1. the otel-collector ClusterIP has ONLY local backends (cilium-dbg service list on a worker's agent);
#   2. the gateway's own metrics: queue size and failed sends (the collector's :8888, through the API-server proxy);
#   3. Tempo (central, poc1) has traces from both clusters in the window.  Usage: check.sh [minutes, default 15]
set -uo pipefail; MIN="${1:-15}"
for C in poc1 poc2; do
  echo "== $C =="
  IP=$(kubectl --context kind-$C -n otel get svc otel-collector -o jsonpath='{.spec.clusterIP}')
  AG=$(kubectl --context kind-$C -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=$C-worker -o name | head -1)
  echo "  otel-collector $IP:4318 backends (as $C-worker's agent sees them):"
  kubectl --context kind-$C -n kube-system exec "$AG" -c cilium-agent -- cilium-dbg service list 2>/dev/null | awk -v ip="$IP:4318/TCP" '$1 ~ /^[0-9]+$/ && $2 ~ /\/TCP$/ {p=($2==ip)} p {print "   ",$0}'
  echo "  annotations: global=[$(kubectl --context kind-$C -n otel get svc otel-collector -o jsonpath='{.metadata.annotations.service\.cilium\.io/global}')] affinity=[$(kubectl --context kind-$C -n otel get svc otel-collector -o jsonpath='{.metadata.annotations.service\.cilium\.io/affinity}')]"
  for P in $(kubectl --context kind-$C -n otel get pods -l app=otel-collector -o name | cut -d/ -f2); do
    kubectl --context kind-$C get --raw "/api/v1/namespaces/otel/pods/$P:8888/proxy/metrics" 2>/dev/null \
      | awk -v p="$P" '/^otelcol_exporter_queue_size\{.*tempo/ {q=$NF} /^otelcol_exporter_send_failed_spans\{.*tempo/ {f=$NF} /^otelcol_exporter_sent_spans\{.*tempo/ {s=$NF} END{printf "  %-34s queue=%s sent=%s failed=%s\n", p, (q==""?"-":q), (s==""?"0":s), (f==""?"0":f)}'
  done
done
echo "== Tempo (central): traces per cluster, last ${MIN} min =="
NOW=$(date +%s)
for C in poc1 poc2; do
  Q=$(python3 -c "import urllib.parse;print(urllib.parse.quote('{ resource.k8s.cluster.name = \"$C\" }'))")
  N=$(kubectl --context kind-poc1 get --raw "/api/v1/namespaces/monitoring/services/tempo:3200/proxy/api/search?q=$Q&start=$((NOW-MIN*60))&end=$NOW&limit=500" 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("traces",[])))')
  echo "  k8s.cluster.name=$C: $N traces"
done
