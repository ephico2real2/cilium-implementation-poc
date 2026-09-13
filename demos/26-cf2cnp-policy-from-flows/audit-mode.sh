#!/usr/bin/env bash
# audit-mode.sh <pod-name-prefix> Enabled|Disabled — flip Cilium's per-endpoint POLICY AUDIT MODE for a pod in cf2cnp-lab.
# Audit mode: policy is evaluated and reported (Hubble verdict AUDIT, hubble_policy_verdicts_total{action="audit"}) but not
# enforced. Set on the agent of the node the pod runs on; it is endpoint-local and does not survive the pod being replaced.
# The endpoint is addressed by its CiliumEndpoint name, `cep-name:<namespace>/<pod>` (cilium v1.20.1 pkg/endpoint/id) —
# no IP matching: a hostNetwork pod has no CiliumEndpoint (404, refused), an IPv6-only pod resolves the same way. The first
# version matched on the pod's IPv4 because 1.20's endpoint list carries no pod name; the review found the prefix.
set -uo pipefail; cd "$(dirname "$0")/../.."; PFX="${1:?pod name prefix}"; MODE="${2:?Enabled|Disabled}"; NS="${NS:-cf2cnp-lab}"   # NS=<namespace> for another lab (demo 27)
case "$MODE" in Enabled|Disabled) ;; *) echo "audit-mode.sh: mode must be Enabled or Disabled" >&2; exit 2 ;; esac
# Running pods only: during a rollout the old pod is still listed (Terminating) and came first — the flag went to the
# endpoint about to die (demo 27 Part 1c). A pod with a deletionTimestamp is excluded too.
POD=$(kubectl --context kind-poc1 -n "$NS" get pods --field-selector status.phase=Running -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    if p['metadata']['name'].startswith('$PFX') and not p['metadata'].get('deletionTimestamp'): print(p['metadata']['name']); break")
[ -n "$POD" ] || { echo "audit-mode.sh: no pod named $PFX* in $NS" >&2; exit 1; }
NODE=$(kubectl --context kind-poc1 -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}')
AG=$(kubectl --context kind-poc1 -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o name | head -1)
ID=$(kubectl --context kind-poc1 -n kube-system exec "$AG" -c cilium-agent -- cilium-dbg endpoint get "cep-name:$NS/$POD" -o json 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print((d[0] if isinstance(d,list) else d)['id'])" 2>/dev/null)
[ -n "$ID" ] || { echo "audit-mode.sh: no Cilium endpoint cep-name:$NS/$POD on $AG (a hostNetwork pod has none)" >&2; exit 1; }
kubectl --context kind-poc1 -n kube-system exec "$AG" -c cilium-agent -- cilium-dbg endpoint config "$ID" PolicyAuditMode="$MODE" >/dev/null && echo "endpoint $ID (cep-name:$NS/$POD on $NODE): PolicyAuditMode=$MODE"
kubectl --context kind-poc1 -n kube-system exec "$AG" -c cilium-agent -- cilium-dbg endpoint config "$ID" 2>/dev/null | grep -i audit | sed 's/^/  /'
