#!/usr/bin/env bash
# hosts-entries.sh (demo37) — the /etc/hosts block for demo 37, its own delimited block, from live state.
# /etc/hosts has no wildcards: every team name is one line (a real zone would be `*.team-b.poc.local`).
#   demos/37-two-gateways/hosts-entries.sh
#   demos/37-two-gateways/hosts-entries.sh | sudo tee -a /etc/hosts
#   sudo sed -i '' '/---- cilium-kind-poc demo37/,/---- end cilium-kind-poc demo37/d' /etc/hosts
# This script never writes /etc/hosts.
set -uo pipefail
CTX="${CTX:-kind-poc1}"
k() { kubectl --context "$CTX" "$@"; }
uniq_hosts() { python3 -c 'import json,sys; names=[]
for r in json.load(sys.stdin).get("items",[]):
    names += r.get("spec",{}).get("hostnames",[])
print(" ".join(dict.fromkeys(names)))'; }

RGW=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
TGW=$(k -n team-b get gateway team-b-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
# shop-a.poc.local from team-a's HTTPRoutes on routes-gw; team-b's HTTPRoute hostnames live on team-b-gw (.243).
A_NAMES=$(k -n team-a get httproute -o json 2>/dev/null | uniq_hosts || true)
B_NAMES=$(k -n team-b get httproute -o json 2>/dev/null | uniq_hosts || true)

echo "# ---- cilium-kind-poc demo37 (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/37-two-gateways/hosts-entries.sh) ----"
# /etc/hosts has no wildcards, so every team name is one line.
if [ -n "$RGW" ] && [ -n "$A_NAMES" ]; then
  echo "$RGW  $A_NAMES"
else
  echo "# WARNING: routes-gw address or team-a HTTPRoute hostnames missing" >&2
fi
if [ -n "$TGW" ] && [ -n "$B_NAMES" ]; then
  echo "$TGW  $B_NAMES"
else
  echo "# WARNING: team-b-gw address or team-b HTTPRoute hostnames missing" >&2
fi
echo "# ---- end cilium-kind-poc demo37 ----"
