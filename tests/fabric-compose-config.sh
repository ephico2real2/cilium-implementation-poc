#!/usr/bin/env bash
# test: fabric compose files parse; committed leaf frr.conf has no secret.
# usage: bash tests/fabric-compose-config.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
FABRIC=$R/demos/46-bgp-fabric/fabric
# shellcheck disable=SC1091
. "$R/scripts/bootstrap/versions-eg.env"
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.5.3}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"
export FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"

cd "$FABRIC"
docker compose -p bgp-fabric-check -f compose.yaml config >/dev/null
docker compose -p bgp-fabric-check -f compose.yaml -f compose.lan-eg.yaml config >/dev/null
docker compose -p bgp-fabric-check -f compose.yaml -f compose.lan-cilium.yaml config >/dev/null
docker compose -p bgp-fabric-check -f compose.yaml -f compose.lan-eg.yaml -f compose.lan-cilium.yaml config >/dev/null

bad=0
for f in frr/leaf1/frr.conf frr/leaf2/frr.conf frr/edge/frr.conf frr/spine/frr.conf; do
  if grep -F -q 'lab-bgp' "$f"; then
    echo "FAIL: $f contains literal lab-bgp"
    bad=1
  fi
  if grep -E '^[[:space:]]*neighbor .* password [^$]' "$f" | grep -v 'password \${FABRIC_BGP_PASSWORD}'; then
    echo "FAIL: $f has a neighbor password that is not the placeholder"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1

echo "TEST PASS: compose config parses (base, eg, cilium, both); frr.conf has no literal password"
exit 0
