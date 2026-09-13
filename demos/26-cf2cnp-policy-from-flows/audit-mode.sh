#!/usr/bin/env bash
# audit-mode.sh <pod-name-prefix> Enabled|Disabled — flip Cilium's per-endpoint POLICY AUDIT MODE for a pod in cf2cnp-lab.
# Audit mode: policy is evaluated and reported (Hubble verdict AUDIT, hubble_policy_verdicts_total{action="audit"}) but not
# enforced. Set on the agent of the node the pod runs on; it is endpoint-local and does not survive the pod being replaced.
set -uo pipefail; cd "$(dirname "$0")/../.."; PFX="${1:?pod name prefix}"; MODE="${2:?Enabled|Disabled}"
POD=$(kubectl --context kind-poc1 -n cf2cnp-lab get pods -o name | grep "/$PFX" | head -1 | cut -d/ -f2)
[ -n "$POD" ] || { echo "audit-mode.sh: no pod named $PFX* in cf2cnp-lab" >&2; exit 1; }
NODE=$(kubectl --context kind-poc1 -n cf2cnp-lab get pod "$POD" -o jsonpath='{.spec.nodeName}')
AG=$(kubectl --context kind-poc1 -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o name | head -1)
# Cilium 1.20's endpoint JSON carries no pod name (external-identifiers holds only the cni-attachment-id, measured), so the
# endpoint is matched on the pod's IPv4 address instead.
# A hostNetwork pod's podIP is the node's IP, shared with every other hostNetwork pod on it — no unique endpoint to flip
# (review finding, demo 26 REVIEW). The match must also be unique on the agent, or the script refuses.
[ "$(kubectl --context kind-poc1 -n cf2cnp-lab get pod "$POD" -o jsonpath='{.spec.hostNetwork}')" != "true" ] || { echo "audit-mode.sh: $POD is hostNetwork — its IP is the node's, no per-pod endpoint to configure" >&2; exit 1; }
IP=$(kubectl --context kind-poc1 -n cf2cnp-lab get pod "$POD" -o jsonpath='{.status.podIP}')
ID=$(kubectl --context kind-poc1 -n kube-system exec "$AG" -c cilium-agent -- cilium-dbg endpoint list -o json 2>/dev/null | python3 -c "
import json,sys
hits=[e['id'] for e in json.load(sys.stdin) if any(a.get('ipv4')=='$IP' for a in (e.get('status',{}).get('networking') or {}).get('addressing',[]))]
if len(hits)!=1: sys.stderr.write('audit-mode.sh: IPv4 $IP matched %d endpoints on this agent (need exactly 1)\n' % len(hits)); print('')
else: print(hits[0])")
[ -n "$ID" ] || { echo "audit-mode.sh: no endpoint with IP $IP on $AG (pod $POD)" >&2; exit 1; }
kubectl --context kind-poc1 -n kube-system exec "$AG" -c cilium-agent -- cilium-dbg endpoint config "$ID" PolicyAuditMode="$MODE" >/dev/null && echo "endpoint $ID ($POD on $NODE): PolicyAuditMode=$MODE"
kubectl --context kind-poc1 -n kube-system exec "$AG" -c cilium-agent -- cilium-dbg endpoint config "$ID" 2>/dev/null | grep -i audit | sed 's/^/  /'
