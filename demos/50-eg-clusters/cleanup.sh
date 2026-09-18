#!/usr/bin/env bash
# cleanup.sh — demo 50 tears down by calling scripts/eg-down.sh (deletes eg1, eg2
# and the kind-eg network). Does not touch poc1, poc2, CRC, or the kind network.
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "demo 50 cleanup: calling scripts/eg-down.sh"
exec scripts/eg-down.sh
