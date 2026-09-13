#!/usr/bin/env bash
# cleanup.sh — put demo 26's lab back the way demo 26 left it: pos loses the egress policy this demo generated
# (toFQDNs + the DNS rule), so its lookups leave the DNS proxy and its next flows carry no names again. The lab
# itself (namespace cf2cnp-lab, the shop policies) belongs to demo 26 and stays; output/ and policies/ stay.
set -uo pipefail; cd "$(dirname "$0")/../.."
kubectl --context kind-poc1 -n cf2cnp-lab delete ciliumnetworkpolicy pos --ignore-not-found
echo "cf2cnp-lab/pos policy deleted; the demo 26 lab is untouched; output/ and policies/ kept"
