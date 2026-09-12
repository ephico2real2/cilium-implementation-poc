#!/usr/bin/env bash
# hosts-entries.sh (bank) — print the /etc/hosts block for demo 15, generated from LIVE state, in
# its OWN delimited block so it can be added and removed independently of the demo 09 block.
# A clone of scripts/hosts-entries.sh, scoped to the bank's HTTPRoutes.
#
# Print it, review it, then add it yourself (this script never touches /etc/hosts):
#   demos/15-bank/hosts-entries.sh
#   sudo sh -c 'demos/15-bank/hosts-entries.sh >> /etc/hosts'
#   grep -c 'bank.poc.local' /etc/hosts        # 1 line, 2 names
# Remove it later:
#   sudo sed -i '' '/---- cilium-kind-poc bank/,/---- end cilium-kind-poc bank/d' /etc/hosts
set -uo pipefail
CTX="${CTX:-kind-poc1}"
k() { kubectl --context "$CTX" "$@"; }
GW=$(k -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
NAMES=$(k -n routes get httproute bank bank-api -o json 2>/dev/null | python3 -c '
import json, sys
names = []
for r in json.load(sys.stdin)["items"]:
    names += r["spec"].get("hostnames", [])
print(" ".join(dict.fromkeys(names)))')
echo "# ---- cilium-kind-poc bank (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/15-bank/hosts-entries.sh) ----"
if [ -n "$GW" ] && [ -n "$NAMES" ]; then
  echo "$GW  $NAMES"
else
  echo "# WARNING: Gateway routes/routes-gw has no address or the bank HTTPRoutes are missing" >&2
fi
echo "# ---- end cilium-kind-poc bank ----"
