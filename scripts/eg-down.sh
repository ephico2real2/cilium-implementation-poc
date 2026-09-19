#!/usr/bin/env bash
# eg-down.sh — delete the vanilla-lab kind clusters (eg1, eg2, eg-poc1) and the
# `kind-eg` docker network. Does NOT touch poc1, poc2, CRC, or the `kind`
# network. Demo 50's cleanup (`demos/50-eg-clusters/cleanup.sh` calls this).
# First real run: 2026-09-18T22:41:16Z.
set -uo pipefail
for c in eg1 eg2 eg-poc1; do
  if kind get clusters 2>/dev/null | grep -qx "$c"; then
    kind delete cluster --name "$c"
  fi
done
if docker network inspect kind-eg >/dev/null 2>&1; then
  docker network rm kind-eg
fi
