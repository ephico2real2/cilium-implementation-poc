#!/usr/bin/env bash
# fabric-vm-route.sh — print the two Mac-path lines for the Envoy VIP block.
#   --apply runs ONLY the VM nsenter line (never sudo).
# The Mac line is for the operator; this script never runs it.
set -euo pipefail

VM_CMD='docker run --rm --privileged --pid=host --net=host alpine:3.20 nsenter -t 1 -m -n -- ip route replace 10.98.0.0/24 via 172.19.254.11'
MAC_CMD='sudo route -n add -net 10.98.0.0/24 192.168.64.2'

echo "VM:  $VM_CMD"
echo "Mac: $MAC_CMD"

if [ "${1:-}" = "--apply" ]; then
  # The orchestrator measured the VM table is reachable this way.
  docker run --rm --privileged --pid=host --net=host alpine:3.20 \
    nsenter -t 1 -m -n -- ip route replace 10.98.0.0/24 via 172.19.254.11
fi
