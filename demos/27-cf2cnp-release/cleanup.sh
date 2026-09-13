#!/usr/bin/env bash
# cleanup.sh — remove demo 27's lab (namespace cf2cnp-lab27: the two shop components, pos, stranger, the policies).
# The audit flags die with the pods. The cf2cnp 0.5.0 release stays: it is what the observability stack runs now.
set -uo pipefail; cd "$(dirname "$0")/../.."
kubectl --context kind-poc1 delete -f demos/27-cf2cnp-release/10-lab.yaml --ignore-not-found --wait=true
kubectl --context kind-poc1 get ns cf2cnp-lab27 2>/dev/null || echo "cf2cnp-lab27 gone"
