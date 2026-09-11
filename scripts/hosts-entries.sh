#!/usr/bin/env bash
# hosts-entries.sh — print the /etc/hosts block for this PoC, generated from LIVE cluster state.
#
# Usage (print it, review it, then add it yourself — this script never touches /etc/hosts):
#   scripts/hosts-entries.sh
#   scripts/hosts-entries.sh | sudo tee -a /etc/hosts
#
# WHY GENERATED AND NOT HARDCODED. LoadBalancer addresses are pinned in this repo (gotcha #13),
# but "pinned in a YAML file" and "what the cluster is serving right now" are two different facts.
# This reads the second one. If a Gateway is not programmed yet, its names are omitted with a
# warning rather than written with a guess.
#
# WHY /etc/hosts CANNOT DO THE WILDCARD. Every name must be listed; *.poc.local is not expressible.
# The wildcard CERTIFICATE still covers any name you add here later. For a true wildcard NAME see
# demos/09-routes/README.md Part 3c (dnsmasq).
set -uo pipefail
CTX="${CTX:-kind-poc1}"
k() { kubectl --context "$CTX" "$@"; }

addr_of_gateway() { k -n "$1" get gateway "$2" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null; }
addr_of_svc()     { k -n "$1" get svc "$2" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null; }

ROUTES_GW=$(addr_of_gateway routes routes-gw)
SW_GW=$(addr_of_gateway default sw-gateway)
HUBBLE_LB=$(addr_of_svc kube-system hubble-ui)

echo "# ---- cilium-kind-poc (generated $(date -u +%Y-%m-%dT%H:%MZ) by scripts/hosts-entries.sh) ----"
if [ -n "$ROUTES_GW" ]; then
  echo "$ROUTES_GW  hubble.poc.local web.poc.local anything-at-all.poc.local grpc.poc.local exact.example.test"
else
  echo "# WARNING: Gateway routes/routes-gw has no address yet; demo 09 names omitted" >&2
fi
if [ -n "$SW_GW" ]; then
  echo "$SW_GW  deathstar.poc.local"
else
  echo "# WARNING: Gateway default/sw-gateway has no address; demo 05 name omitted" >&2
fi
if [ -n "$HUBBLE_LB" ]; then
  echo "$HUBBLE_LB  hubble-direct.poc.local"
fi
echo "# ---- end cilium-kind-poc ----"
