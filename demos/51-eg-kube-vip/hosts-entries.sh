#!/usr/bin/env bash
# hosts-entries.sh (demo 51) — the /etc/hosts block for the EG doors, from LIVE state.
#   demos/51-eg-kube-vip/hosts-entries.sh
#   demos/51-eg-kube-vip/hosts-entries.sh | sudo tee -a /etc/hosts
# This script never writes /etc/hosts. The four API/product names plus the two
# per-cluster gRPC names (six SANs on eg-tls).
set -uo pipefail
cd "$(dirname "$0")/../.."
addr_of() { # ctx name
  kubectl --context "$1" -n shop get gateway "$2" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

VIP=$(addr_of kind-eg1 eg-vip-gw)
if [ -z "$VIP" ]; then
  VIP=$(addr_of kind-eg2 eg-vip-gw)
fi
EG1=$(addr_of kind-eg1 eg1-gw)
EG2=$(addr_of kind-eg2 eg2-gw)

echo "# ---- cilium-kind-poc demo51 (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/51-eg-kube-vip/hosts-entries.sh) ----"
if [ -n "$VIP" ]; then
  echo "$VIP  api.eg.poc.local grpc.eg.poc.local"
else
  echo "# WARNING: eg-vip-gw has no address yet" >&2
fi
if [ -n "$EG1" ]; then
  echo "$EG1  api.eg1.poc.local grpc.eg1.poc.local"
else
  echo "# WARNING: eg1-gw has no address yet" >&2
fi
if [ -n "$EG2" ]; then
  echo "$EG2  api.eg2.poc.local grpc.eg2.poc.local"
else
  echo "# WARNING: eg2-gw has no address yet" >&2
fi
echo "# ---- end cilium-kind-poc demo51 ----"
