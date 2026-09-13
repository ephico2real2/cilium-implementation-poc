#!/usr/bin/env bash
# cleanup.sh — remove the shop platform: the six namespaces take their workloads, ConfigMaps, the five default-deny policies
# and the six generated ones with them. The audit flags died with the pods. output/ and policies/ stay.
set -uo pipefail; cd "$(dirname "$0")/../.."
for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews shop-clients; do
  kubectl --context kind-poc1 delete namespace "$ns" --ignore-not-found --wait=false
done
echo "the six shop namespaces are deleting (the pods take a moment); output/ and policies/ kept"
