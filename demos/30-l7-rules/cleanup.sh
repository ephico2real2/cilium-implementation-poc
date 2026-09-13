#!/usr/bin/env bash
# cleanup.sh — remove the demo 30 lab. The namespace takes the pods, the ConfigMap, the visibility policy (if it is
# still there), the default-deny and the two generated L7 policies with it. The recorded output/ and policies/ stay.
set -uo pipefail; cd "$(dirname "$0")/../.."
kubectl --context kind-poc1 delete namespace cf2cnp-lab30 --ignore-not-found --wait=false
echo "cf2cnp-lab30 deleted (the pods take a moment to terminate); output/ and policies/ kept"
