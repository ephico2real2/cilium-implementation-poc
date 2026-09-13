#!/usr/bin/env bash
# cleanup.sh — remove the demo 29 lab from BOTH clusters. The namespace takes its pods, the global Service and the four
# policies with it; the audit flag on the cache endpoint dies with the pod (it is endpoint-local, demo 26). Nothing here
# touches the hubble-observer release, Cilium's metrics values on poc2 (Part 1 stays: the policy metric is wanted), or
# the recorded output/.
set -uo pipefail; cd "$(dirname "$0")/../.."
for c in poc1 poc2; do
  kubectl --context "kind-$c" delete namespace mesh-lab --ignore-not-found --wait=false
done
echo "mesh-lab deleted in poc1 and poc2 (the pods take a moment to terminate); output/ kept"
