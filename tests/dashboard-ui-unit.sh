#!/usr/bin/env bash
# test: syntax and node --test for the dashboard UI helpers.
#
# Delegated to bgp-fabric's own suite, at the pinned commit — see
# tests/fabric-dashboard-unit.sh for why.
# usage: bash tests/dashboard-ui-unit.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
BGP_FABRIC=$("$R/scripts/bgp-fabric-fetch.sh")
exec "$BGP_FABRIC/tests/dashboard-ui-unit.sh"
