#!/usr/bin/env bash
# hosts-entries.sh (demo 52) — the /etc/hosts block for the two doors, from LIVE state.
#   demos/52-eg-poc2-metallb/hosts-entries.sh
#   demos/52-eg-poc2-metallb/hosts-entries.sh | sudo tee -a /etc/hosts
# This script never writes /etc/hosts. api.eg-poc2.poc.local → .150,
# grpc.eg-poc2.poc.local → .151.
set -uo pipefail
cd "$(dirname "$0")/../.."
addr_of() { # name
  kubectl --context kind-eg-poc2 -n shop get gateway "$1" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

HTTP=$(addr_of http-gw)
GRPC=$(addr_of grpc-gw)

echo "# ---- cilium-kind-poc demo52 (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/52-eg-poc2-metallb/hosts-entries.sh) ----"
if [ -n "$HTTP" ]; then
  echo "$HTTP  api.eg-poc2.poc.local"
else
  echo "# WARNING: http-gw has no address yet" >&2
  echo "172.19.255.150  api.eg-poc2.poc.local"
fi
if [ -n "$GRPC" ]; then
  echo "$GRPC  grpc.eg-poc2.poc.local"
else
  echo "# WARNING: grpc-gw has no address yet" >&2
  echo "172.19.255.151  grpc.eg-poc2.poc.local"
fi
echo "# ---- end cilium-kind-poc demo52 ----"
