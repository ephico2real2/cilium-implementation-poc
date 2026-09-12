#!/usr/bin/env bash
# cleanup.sh — remove demo 26's lab. The audit-mode flag lives on the endpoint and dies with the pod, so deleting the
# namespace clears it too; the generated policies are namespaced and go with it. Nothing outside cf2cnp-lab is touched
# (the policy dynamic metric added in Part 4a stays: it is part of demo 16's values now).
set -uo pipefail; cd "$(dirname "$0")/../.."
kubectl --context kind-poc1 delete -f demos/26-cf2cnp-policy-from-flows/10-lab.yaml --ignore-not-found --wait=true
kubectl --context kind-poc1 get ns cf2cnp-lab 2>/dev/null || echo "cf2cnp-lab gone"
