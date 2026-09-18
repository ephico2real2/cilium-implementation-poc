#!/usr/bin/env bash
# eg-down.sh — delete the vanilla-lab kind clusters (eg1, eg2) and the `kind-eg` docker network.
# Does NOT touch poc1, poc2, CRC, or the `kind` network. Written in phase 0; not run here —
# demo 50's cleanup. `bash -n` is the phase-0 check.
set -uo pipefail
for c in eg1 eg2; do
  if kind get clusters 2>/dev/null | grep -qx "$c"; then
    kind delete cluster --name "$c"
  fi
done
if docker network inspect kind-eg >/dev/null 2>&1; then
  docker network rm kind-eg
fi
