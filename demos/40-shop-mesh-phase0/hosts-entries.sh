#!/usr/bin/env bash
# hosts-entries.sh (demo 40) — the /etc/hosts block for the shop doors, from LIVE state.
#   demos/40-shop-mesh-phase0/hosts-entries.sh
#   demos/40-shop-mesh-phase0/hosts-entries.sh | sudo tee -a /etc/hosts
# This script never writes /etc/hosts.
set -uo pipefail
addr_of() { # ctx ns name
  kubectl --context "$1" -n "$2" get gateway "$3" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

VIP=$(addr_of kind-poc1 shop-edge shop-vip-gw)
POC1=$(addr_of kind-poc1 shop-edge shop-gw)
POC2=$(addr_of kind-poc2 shop-edge shop-gw)
DB=$(addr_of kind-poc1 shop-edge db-gw)

echo "# ---- cilium-kind-poc demo40 (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/40-shop-mesh-phase0/hosts-entries.sh) ----"
if [ -n "$VIP" ]; then
  echo "$VIP  api.shop.poc.local"
else
  echo "# WARNING: poc1 shop-vip-gw has no address yet" >&2
fi
if [ -n "$POC1" ]; then
  echo "$POC1  api.poc1.shop.poc.local"
else
  echo "# WARNING: poc1 shop-gw has no address yet" >&2
fi
if [ -n "$POC2" ]; then
  echo "$POC2  api.poc2.shop.poc.local"
else
  echo "# WARNING: poc2 shop-gw has no address yet" >&2
fi
if [ -n "$DB" ]; then
  echo "$DB  db-service.poc.local"
else
  echo "# db-service.poc.local  — phase 2 (db-gw does not exist yet)"
fi
echo "# ---- end cilium-kind-poc demo40 ----"
