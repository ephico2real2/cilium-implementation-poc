#!/usr/bin/env bash
# audit-all.sh Enabled|Disabled — flip policy audit mode on EVERY shop workload pod across the five service namespaces,
# with demo 26's audit-mode.sh (one endpoint at a time, by CiliumEndpoint name, Running pods only). Audit mode is
# endpoint-local and dies with the pod (gotcha #84), so run it again after any rollout.
set -uo pipefail; cd "$(dirname "$0")/../.."; MODE="${1:?Enabled|Disabled}"
for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews; do
  for pod in $(kubectl --context kind-poc1 -n "$ns" get pods -l app.kubernetes.io/part-of=shop --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
    NS="$ns" demos/26-cf2cnp-policy-from-flows/audit-mode.sh "$pod" "$MODE" | grep -E "endpoint|PolicyAuditMode" | head -1
  done
done
