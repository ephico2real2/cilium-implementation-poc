#!/usr/bin/env bash
# apply-poc2.sh — the demo 16 Cilium metrics values on poc2: the SAME file as poc1 with the cluster label rewritten
# (relabelings are lists, an overlay cannot change one element, so the file is rewritten, not layered) plus the poc2
# overrides. The agents restart once (prometheus.enabled adds a container port; the dynamic-metrics volume is new).
set -euo pipefail; cd "$(dirname "$0")/../.."
sed 's/replacement: poc1/replacement: poc2/g' demos/16-monitoring/values-cilium-metrics.yaml > .tmp/values-cilium-metrics-poc2.yaml
echo "  cluster=poc2 relabelings: $(grep -c 'replacement: poc2' .tmp/values-cilium-metrics-poc2.yaml)"
helm get values cilium -n kube-system --kube-context kind-poc2 -o yaml > .tmp/poc2-values-before-demo22.yaml
helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION:-1.20.2}" -n kube-system --kube-context kind-poc2 --reuse-values \
  -f .tmp/values-cilium-metrics-poc2.yaml -f demos/22-multicluster-observability/values-cilium-metrics-poc2-overrides.yaml | grep -E "Release|Error"
kubectl --context kind-poc2 -n kube-system rollout status ds/cilium --timeout=8m | tail -1
kubectl --context kind-poc2 -n kube-system get servicemonitor -o custom-columns='SERVICEMONITOR:.metadata.name,PORT:.spec.endpoints[0].port'
