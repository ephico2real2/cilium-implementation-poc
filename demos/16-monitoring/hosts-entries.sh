#!/usr/bin/env bash
# hosts-entries.sh (monitoring) — the /etc/hosts block for demo 16, its own delimited block, from live state.
#   demos/16-monitoring/hosts-entries.sh
#   sudo sh -c 'demos/16-monitoring/hosts-entries.sh >> /etc/hosts'
#   sudo sed -i '' '/---- cilium-kind-poc monitoring/,/---- end cilium-kind-poc monitoring/d' /etc/hosts
set -uo pipefail
CTX="${CTX:-kind-poc1}"
GW=$(kubectl --context "$CTX" -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
NAMES=$(kubectl --context "$CTX" -n routes get httproute grafana -o jsonpath='{.spec.hostnames[*]}' 2>/dev/null)
echo "# ---- cilium-kind-poc monitoring (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/16-monitoring/hosts-entries.sh) ----"
[ -n "$GW" ] && [ -n "$NAMES" ] && echo "$GW  $NAMES" || echo "# WARNING: Gateway address or the grafana HTTPRoute missing" >&2
echo "# ---- end cilium-kind-poc monitoring ----"
