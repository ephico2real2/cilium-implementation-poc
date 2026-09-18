#!/usr/bin/env bash
# eg-net.sh — create the vanilla-lab Docker network `kind-eg` (172.19.0.0/16), idempotent.
# Mirrors scripts/lab-up.sh:112-124 and NETWORKING_DESIGN.md:115-116: a second LAN, not a share of
# `kind` (172.18.0.0/16). Docker's container allocation is held to the lower half (--ip-range
# 172.19.0.0/17) so the reserved VIP /24 at 172.19.255.0/24 can never be a node address.
#
# Options that matter (the rest are mirrored from `docker network inspect kind` so dual-stack
# kind nodes attach the same way):
#   --subnet 172.19.0.0/16          the LAN this lab's address plan is written for
#   --ip-range 172.19.0.0/17        the reservation trick — Docker IPAM never reaches .255.0/24
#   --gateway 172.19.0.1            stable .1, same shape as `kind`
#   enable_ip_masquerade=true       nodes pull images through the VM's NAT
#   driver.mtu                      copied from the default `bridge` (65535 on this Docker Desktop)
#   --ipv6 + a unique ULA           `kind` is dual-stack (fc00:f853:ccd:e793::/64); this lab uses
#                                   the adjacent prefix so the two bridges cannot share a subnet
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env

NAME="${EG_NETWORK_NAME:-kind-eg}"
SUBNET="${EG_SUBNET:-172.19.0.0/16}"
IP_RANGE="${EG_IP_RANGE:-172.19.0.0/17}"
GATEWAY="${EG_GATEWAY:-172.19.0.1}"
SUBNET6="${EG_SUBNET6:-fc00:f853:ccd:e794::/64}"

if docker network inspect "$NAME" >/dev/null 2>&1; then
  have=$(docker network inspect "$NAME" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  if [ "$have" != "$SUBNET" ]; then
    echo "eg-net: docker network '$NAME' exists with subnet $have, not $SUBNET — delete it (no cluster must be on it) or set EG_SUBNET to match" >&2
    exit 1
  fi
  echo "exists with $have, kept"
  exit 0
fi

mtu=$(docker network inspect bridge --format '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null) || true
[ -n "${mtu:-}" ] || mtu=1500

if ! docker network create -d bridge \
    --subnet "$SUBNET" --ip-range "$IP_RANGE" --gateway "$GATEWAY" \
    -o com.docker.network.bridge.enable_ip_masquerade=true \
    -o com.docker.network.driver.mtu="$mtu" \
    --ipv6 --subnet "$SUBNET6" \
    "$NAME"; then
  echo "eg-net: docker daemon refused --ipv6; creating IPv4-only $NAME" >&2
  docker network create -d bridge \
    --subnet "$SUBNET" --ip-range "$IP_RANGE" --gateway "$GATEWAY" \
    -o com.docker.network.bridge.enable_ip_masquerade=true \
    -o com.docker.network.driver.mtu="$mtu" \
    "$NAME"
fi
echo "created: $(docker network inspect "$NAME" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')"
