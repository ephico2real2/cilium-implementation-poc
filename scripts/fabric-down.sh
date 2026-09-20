#!/usr/bin/env bash
# fabric-down.sh — stop the company BGP fabric (project bgp-fabric).
# Removes the fabric's own networks (link-*, wan). Never removes kind or
# kind-eg (external). Does not touch poc1/poc2/eg-poc1/eg-poc2/CRC.
# Images stay unless --rmi (removes frr-agent:local and bgp-dashboard:local).
set -euo pipefail
cd "$(dirname "$0")/.."
FABRIC=demos/46-bgp-fabric/fabric
PROJECT="${FABRIC_PROJECT:-bgp-fabric}"
rmi=0
if [ "${1:-}" = --rmi ]; then
  rmi=1
elif [ $# -gt 0 ]; then
  echo "usage: $0 [--rmi]" >&2
  exit 2
fi
# compose.yaml only: `down` still stops every container in the project,
# including those started with an overlay. External networks stay.
docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" down --remove-orphans
if [ "$rmi" -eq 1 ]; then
  docker image rm -f "${FABRIC_ROUTER_IMAGE:-frr-agent:local}" \
    "${FABRIC_DASHBOARD_IMAGE:-bgp-dashboard:local}" >/dev/null 2>&1 || true
  echo "fabric-down: project $PROJECT stopped; local images removed (kind / kind-eg kept)"
else
  echo "fabric-down: project $PROJECT stopped (kind / kind-eg kept; images stay unless --rmi)"
fi
