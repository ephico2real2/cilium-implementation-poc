#!/usr/bin/env bash
# hosts-entries.sh (demo 54) — the /etc/hosts block for the two doors, from LIVE state.
#   demos/54-eg-poc1-kube-vip/hosts-entries.sh
#   demos/54-eg-poc1-kube-vip/hosts-entries.sh | sudo tee -a /etc/hosts
# This script never writes /etc/hosts. api.eg-poc1.poc.local → .100,
# grpc.eg-poc1.poc.local → .101.
set -uo pipefail
cd "$(dirname "$0")/../.."
addr_of() { # name
  kubectl --context kind-eg-poc1 -n shop get gateway "$1" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

HTTP=$(addr_of http-gw)
GRPC=$(addr_of grpc-gw)

echo "# ---- cilium-kind-poc demo54 (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/54-eg-poc1-kube-vip/hosts-entries.sh) ----"
if [ -n "$HTTP" ]; then
  echo "$HTTP  api.eg-poc1.poc.local"
else
  echo "# WARNING: http-gw has no address yet" >&2
  echo "172.19.255.100  api.eg-poc1.poc.local"
fi
if [ -n "$GRPC" ]; then
  echo "$GRPC  grpc.eg-poc1.poc.local"
else
  echo "# WARNING: grpc-gw has no address yet" >&2
  echo "172.19.255.101  grpc.eg-poc1.poc.local"
fi
echo "# ---- end cilium-kind-poc demo54 ----"
