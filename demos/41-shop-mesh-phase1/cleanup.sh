#!/usr/bin/env bash
# cleanup.sh — remove phase 1's routes, policies and platform from both clusters.
# Leaves demo 40's doors (shop-gw, shop-vip-gw, shop-tls, the VIP announcer, shared-vip-pool).
# shop-edge is kept (demo 40 created it); the other shop namespaces go.
#
#   demos/41-shop-mesh-phase1/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)

for ctx in "${CTX_ARR[@]}"; do
  echo "== $ctx"
  kubectl --context "$ctx" -n shop-edge delete httproute shop-api shop-redirect --ignore-not-found
  for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews; do
    kubectl --context "$ctx" -n "$ns" delete ciliumnetworkpolicy --all --ignore-not-found
  done
  # platform workloads: delete the namespaces that phase 1 created, keep shop-edge (the doors)
  for ns in shop-core shop-payments shop-merchant shop-reviews shop-clients; do
    kubectl --context "$ctx" delete namespace "$ns" --ignore-not-found --wait=false
  done
  # shop-edge keeps the Gateways; drop the platform Deployment/Service/ConfigMap living next to them
  kubectl --context "$ctx" -n shop-edge delete deploy api-gateway --ignore-not-found
  kubectl --context "$ctx" -n shop-edge delete svc api-gateway --ignore-not-found
  kubectl --context "$ctx" -n shop-edge delete configmap api-gateway-nginx --ignore-not-found
done

echo "phase 1 removed (KEPT: demo 40's doors, shop-tls, shop-vip-announce, shared-vip-pool, namespace shop-edge)"
