#!/usr/bin/env bash
# Usage: test_compose_collector.sh <compose.yaml> <collector config>
# 1. GOMEMLIMIT is set to 80% of memory_limiter's limit_mib (the processor README's advice).
# 2. Every public image is registry-qualified, as the rest of the file is.
set -u
limit="$(grep -oE 'limit_mib: [0-9]+' "$2" | head -1 | grep -oE '[0-9]+$')"
want="$((limit * 8 / 10))MiB"
got="$(podman compose -f "$1" config --format json 2>/dev/null \
  | python3 -c 'import json,sys; print((json.load(sys.stdin)["services"]["otel-collector"].get("environment") or {}).get("GOMEMLIMIT", "unset"))')"
unqualified="$(grep -nE '^\s+image: ' "$1" | grep -vE 'image: (docker\.io|icr\.io|ghcr\.io|quay\.io|localhost)/' | tr -s ' ')"
echo "GOMEMLIMIT: want ${want}, got ${got}; unqualified images: ${unqualified:-none}"
[ "${got}" = "${want}" ] && [ -z "${unqualified}" ]
