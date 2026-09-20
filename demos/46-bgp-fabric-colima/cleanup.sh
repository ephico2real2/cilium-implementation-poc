#!/usr/bin/env bash
# cleanup.sh — stop project bgp-fabric-colima in the Colima VM.
# Does not touch Desktop's bgp-fabric, md5lab, kind, kind-eg, or CRC.
#   demos/46-bgp-fabric-colima/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi
scripts/fabric-colima-down.sh
echo "demo 46-colima removed (KEPT: Colima profile $FABRIC_COLIMA_PROFILE; Desktop fabric and kind clusters untouched)"
