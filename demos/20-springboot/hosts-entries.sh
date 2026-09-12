#!/usr/bin/env bash
# hosts-entries.sh (springboot) — its own delimited /etc/hosts block, from live state.
#   sudo sh -c 'demos/20-springboot/hosts-entries.sh >> /etc/hosts'
#   sudo sed -i '' '/---- cilium-kind-poc springboot/,/---- end cilium-kind-poc springboot/d' /etc/hosts
set -uo pipefail; CTX="${CTX:-kind-poc1}"
GW=$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
NAMES=$(kubectl --context "$CTX" -n routes get httproute petclinic -o jsonpath='{.spec.hostnames[*]}' 2>/dev/null)
echo "# ---- cilium-kind-poc springboot (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/20-springboot/hosts-entries.sh) ----"
[ -n "$GW" ] && [ -n "$NAMES" ] && echo "$GW  $NAMES" || echo "# WARNING: Gateway address or the petclinic HTTPRoute missing" >&2
echo "# ---- end cilium-kind-poc springboot ----"
