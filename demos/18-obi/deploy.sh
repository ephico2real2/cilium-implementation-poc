#!/usr/bin/env bash
# deploy.sh <poc1|poc2> — apply 10-obi.yaml to one cluster with its name stamped into OTEL_RESOURCE_ATTRIBUTES.
set -euo pipefail
C="${1:?usage: deploy.sh poc1|poc2}"; cd "$(dirname "$0")"
sed "s/__CLUSTER__/$C/" 10-obi.yaml | kubectl --context "kind-$C" apply -f -
# a ConfigMap change does not restart the pods: restart, so the config on disk is the config running
kubectl --context "kind-$C" -n obi rollout restart ds/obi >/dev/null
kubectl --context "kind-$C" -n obi rollout status ds/obi --timeout=3m
# the PodMonitor needs the Prometheus Operator CRDs — only where the demo 16 stack is (poc1)
if kubectl --context "kind-$C" get crd podmonitors.monitoring.coreos.com >/dev/null 2>&1; then
  sed "s/__CLUSTER__/$C/" 30-podmonitor.yaml | kubectl --context "kind-$C" apply -f -
else
  echo "(no monitoring.coreos.com CRDs in $C: PodMonitor skipped — OBI metrics stay unscraped here)"
fi
