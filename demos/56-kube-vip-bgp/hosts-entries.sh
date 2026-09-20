#!/usr/bin/env bash
# hosts-entries.sh (demo 56) — the /etc/hosts block for the routed doors.
#   demos/56-kube-vip-bgp/hosts-entries.sh
#   demos/56-kube-vip-bgp/hosts-entries.sh | sudo tee -a /etc/hosts
# This script never writes /etc/hosts. api.eg-poc1.poc.local → 10.98.0.10,
# grpc.eg-poc1.poc.local → 10.98.0.11. Same names as demo 54, new
# addresses — this block replaces demo 54's for those names. Demo 54's
# L2 doors (.100/.101) stop answering once this demo is applied.
set -uo pipefail
cd "$(dirname "$0")/../.."
addr_of() { # name
  kubectl --context kind-eg-poc1 -n shop get gateway "$1" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

HTTP=$(addr_of bgp-http-gw)
GRPC=$(addr_of bgp-grpc-gw)

echo "# ---- cilium-kind-poc demo56 (generated $(date -u +%Y-%m-%dT%H:%MZ) by demos/56-kube-vip-bgp/hosts-entries.sh) ----"
if [ -n "$HTTP" ]; then
  echo "$HTTP  api.eg-poc1.poc.local"
else
  echo "# WARNING: bgp-http-gw has no address yet" >&2
  echo "10.98.0.10  api.eg-poc1.poc.local"
fi
if [ -n "$GRPC" ]; then
  echo "$GRPC  grpc.eg-poc1.poc.local"
else
  echo "# WARNING: bgp-grpc-gw has no address yet" >&2
  echo "10.98.0.11  grpc.eg-poc1.poc.local"
fi
echo "# ---- end cilium-kind-poc demo56 ----"
