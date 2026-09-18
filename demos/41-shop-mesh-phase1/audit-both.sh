#!/usr/bin/env bash
# audit-both.sh Enabled|Disabled — flip policy audit mode on EVERY shop workload pod across the
# five service namespaces, in every context (demo 35's audit-all.sh, generalised; do not modify
# demo 35). Audit mode is endpoint-local and dies with the pod (gotcha #84).
#
#   demos/41-shop-mesh-phase1/audit-both.sh Enabled
#   CONTEXTS="kind-poc2" demos/41-shop-mesh-phase1/audit-both.sh Disabled
set -uo pipefail
cd "$(dirname "$0")/../.."
MODE="${1:?Enabled|Disabled}"
case "$MODE" in Enabled|Disabled) ;; *) echo "audit-both.sh: mode must be Enabled or Disabled" >&2; exit 2 ;; esac
CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)

# one endpoint, generalised from demos/26-cf2cnp-policy-from-flows/audit-mode.sh (that script is
# hardcoded to kind-poc1; this copy takes CONTEXT so poc2 works too).
audit_one() {
  local ctx=$1 ns=$2 pfx=$3
  local pod node ag id
  pod=$(kubectl --context "$ctx" -n "$ns" get pods --field-selector status.phase=Running -o json 2>/dev/null | python3 -c "
import json,sys
pfx='$pfx'
for p in json.load(sys.stdin).get('items',[]):
    if p['metadata']['name'].startswith(pfx) and not p['metadata'].get('deletionTimestamp'):
        print(p['metadata']['name']); break
")
  [ -n "$pod" ] || { echo "audit-both.sh: no pod named $pfx* in $ns on $ctx" >&2; return 1; }
  node=$(kubectl --context "$ctx" -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')
  ag=$(kubectl --context "$ctx" -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName="$node" -o name | head -1)
  id=$(kubectl --context "$ctx" -n kube-system exec "$ag" -c cilium-agent -- cilium-dbg endpoint get "cep-name:$ns/$pod" -o json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print((d[0] if isinstance(d,list) else d)['id'])" 2>/dev/null)
  [ -n "$id" ] || { echo "audit-both.sh: no Cilium endpoint cep-name:$ns/$pod on $ag" >&2; return 1; }
  kubectl --context "$ctx" -n kube-system exec "$ag" -c cilium-agent -- cilium-dbg endpoint config "$id" PolicyAuditMode="$MODE" >/dev/null \
    && echo "$ctx endpoint $id (cep-name:$ns/$pod on $node): PolicyAuditMode=$MODE"
}

rc=0
for ctx in "${CTX_ARR[@]}"; do
  for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews; do
    for pod in $(kubectl --context "$ctx" -n "$ns" get pods -l app.kubernetes.io/part-of=shop --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      audit_one "$ctx" "$ns" "$pod" || rc=1
    done
  done
done
exit "$rc"
