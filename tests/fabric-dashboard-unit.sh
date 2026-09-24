#!/usr/bin/env bash
# test: go test + go vet on the router agent and the dashboard.
#
# The code is bgp-fabric's, so its own suite is what runs — this is a
# delegation, not a second copy of the assertions. Running it here means a
# bad pin fails in this repository rather than only in the other one's CI.
# usage: bash tests/fabric-dashboard-unit.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
BGP_FABRIC=$("$R/scripts/bgp-fabric-fetch.sh")
exec "$BGP_FABRIC/tests/fabric-dashboard-unit.sh"
