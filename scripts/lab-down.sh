#!/usr/bin/env bash
# lab-down.sh — delete the lab's kind clusters (all of them, or the ones named). The docker network `kind` stays.
set -uo pipefail
if [ $# -eq 0 ]; then set -- $(kind get clusters 2>/dev/null); fi
for c in "$@"; do kind delete cluster --name "$c"; done
