#!/usr/bin/env bash
# build.sh — cross-compile shopctl for this Mac and for Linux/amd64 (kind nodes, a colleague's box).
# bin/ is gitignored.
#   demos/40-shop-mesh-phase0/client/go/shopctl/build.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o bin/shopctl-darwin-arm64 .
GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o bin/shopctl-linux-amd64 .
echo "wrote bin/shopctl-darwin-arm64 bin/shopctl-linux-amd64"
