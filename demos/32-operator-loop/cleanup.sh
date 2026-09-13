#!/usr/bin/env bash
# cleanup.sh — put demo 27's lab back the way demo 27 left it: the kiosk pod goes, and shop-frontend's policy is
# demo 27's again (pos only — the merged rule for kiosk is removed with it). The throwaway policies repository and
# its pull request stay on GitHub as the record; output/ and policies/ stay here.
set -uo pipefail; cd "$(dirname "$0")/../.."
kubectl --context kind-poc1 -n cf2cnp-lab27 delete pod kiosk --ignore-not-found --wait=false
kubectl --context kind-poc1 apply -f demos/27-cf2cnp-release/policies/cnp-shop.yaml
echo "kiosk deleted, shop-frontend policy back to demo 27's; the lab repository and PR #1 stay; output/ and policies/ kept"
