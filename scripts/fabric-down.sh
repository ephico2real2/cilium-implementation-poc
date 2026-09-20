#!/usr/bin/env bash
# fabric-down.sh — stop the company BGP fabric (project bgp-fabric).
# Removes the fabric's own networks (link-*, wan). Never removes kind or
# kind-eg (external). Does not touch poc1/poc2/eg-poc1/eg-poc2/CRC.
set -euo pipefail
cd "$(dirname "$0")/.."
FABRIC=demos/46-bgp-fabric/fabric
PROJECT="${FABRIC_PROJECT:-bgp-fabric}"
# compose.yaml only: `down` still stops every container in the project,
# including those started with an overlay. External networks stay.
docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" down --remove-orphans
echo "fabric-down: project $PROJECT stopped (kind / kind-eg kept)"
