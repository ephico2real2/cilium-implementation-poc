#!/usr/bin/env bash
# cleanup.sh — stop the fabric. Leaves kind / kind-eg and every cluster.
#   demos/46-bgp-fabric/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
scripts/fabric-down.sh
echo "demo 46 removed (KEPT: kind, kind-eg, every cluster)"
