#!/usr/bin/env bash
# build.sh — shopapi:local, then kind load into both clusters (four nodes). A build on the Docker
# VM is allowed in this phase (gotcha #118); measurements start in demo 41 after builds are done.
#   demos/40-shop-mesh-phase0/shopapi/build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
docker build -t shopapi:local -f demos/40-shop-mesh-phase0/shopapi/Containerfile demos
kind load docker-image shopapi:local --name poc1
kind load docker-image shopapi:local --name poc2
echo "shopapi:local loaded into poc1 and poc2"
