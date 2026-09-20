#!/usr/bin/env bash
# test: both leaves have maximum-paths 8 (same-AS /32 ECMP on one leaf).
# usage: bash tests/fabric-max-paths.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
grep -E '^ maximum-paths 8$' "$R/demos/46-bgp-fabric/fabric/frr/leaf1/frr.conf"
grep -E '^ maximum-paths 8$' "$R/demos/46-bgp-fabric/fabric/frr/leaf2/frr.conf"
echo "TEST PASS: leaves have maximum-paths 8"
