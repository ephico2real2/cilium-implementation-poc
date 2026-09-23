#!/usr/bin/env bash
# test: go test + go vet on frr-agent and bgp-dashboard.
# usage: bash tests/fabric-dashboard-unit.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
cd "$R/demos/46-bgp-fabric/frr-agent"
go test ./...
go vet ./...
# BOTH copies. The sync gate forces them byte-identical, so a break in one is
# a break in the other — but it is the Go suite that says WHAT broke, and it
# was only ever run in one of them.
for d in demos/46-bgp-fabric demos/46-bgp-fabric-colima; do
  cd "$R/$d/dashboard"
  go test ./...
  go vet ./...
done
echo "TEST PASS: frr-agent and bgp-dashboard go test + go vet (both copies)"
