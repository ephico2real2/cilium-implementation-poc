#!/usr/bin/env bash
# build.sh — docker build grpcdemo:local and kind-load it onto eg-poc2.
#   demos/52-eg-poc2-metallb/grpcdemo/build.sh
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER=${CLUSTER:-eg-poc2}
docker build -t grpcdemo:local -f Containerfile .
kind load docker-image grpcdemo:local --name "$CLUSTER"
