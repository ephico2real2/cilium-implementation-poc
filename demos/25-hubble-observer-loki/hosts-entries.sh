#!/usr/bin/env bash
# hosts-entries.sh (hubble-observer) — its own delimited /etc/hosts block, from live state (the demo 20 pattern).
#   sudo sh -c 'demos/25-hubble-observer-loki/hosts-entries.sh >> /etc/hosts'
#   sudo sed -i '' '/---- cilium-kind-poc hubble-observer/,/---- end cilium-kind-poc hubble-observer/d' /etc/hosts
set -uo pipefail; CTX="${CTX:-kind-poc1}"
GW=$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
NAMES=$(kubectl --context "$CTX" -n routes get httproute cf2cnp -o jsonpath='{.spec.hostnames[*]}' 2>/dev/null)
echo "# ---- cilium-kind-poc hubble-observer (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/25-hubble-observer-loki/hosts-entries.sh) ----"
[ -n "$GW" ] && [ -n "$NAMES" ] && echo "$GW  $NAMES" || echo "# WARNING: Gateway address or the cf2cnp HTTPRoute missing" >&2
echo "# ---- end cilium-kind-poc hubble-observer ----"
