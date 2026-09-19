#!/usr/bin/env bash
# cleanup.sh — remove demo 51's doors, app, kube-vip and the shop namespace.
# Leaves demo 50's clusters (eg1/eg2, Envoy Gateway, cert-manager, the lab root).
# Does not touch poc1, poc2, CRC, or the kind network.
# This is the one demo 51 file the demo-54-eg-poc1 branch may touch: same
# ordering as demo 54 (wait for the Envoy door Services before the
# cloud-provider goes — demo 51 review A1).
#
#   demos/51-eg-kube-vip/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

for ctx in kind-eg1 kind-eg2; do
  echo "== $ctx"
  kubectl --context "$ctx" -n shop delete httproute --all --ignore-not-found
  kubectl --context "$ctx" -n shop delete grpcroute --all --ignore-not-found
  kubectl --context "$ctx" -n shop delete gateway --all --ignore-not-found
  # Door Services carry service.kubernetes.io/load-balancer-cleanup; wait
  # for them to be gone BEFORE the provider goes (demo 54 review A3 / F6).
  kubectl --context "$ctx" -n envoy-gateway-system wait svc \
    -l gateway.envoyproxy.io/owning-gateway-name --for=delete --timeout=60s
  kubectl --context "$ctx" -n shop delete envoyproxy --all --ignore-not-found
  kubectl --context "$ctx" -n shop delete certificate eg-tls --ignore-not-found
  kubectl --context "$ctx" -n shop delete secret eg-tls --ignore-not-found
  kubectl --context "$ctx" delete ns shop --ignore-not-found --wait=false
  kubectl --context "$ctx" -n kube-system delete deploy kube-vip-cloud-provider --ignore-not-found
  kubectl --context "$ctx" -n kube-system delete ds kube-vip-ds --ignore-not-found
  kubectl --context "$ctx" -n kube-system delete cm kubevip --ignore-not-found
  kubectl --context "$ctx" delete clusterrolebinding system:kube-vip-binding system:kube-vip-cloud-controller-binding --ignore-not-found
  kubectl --context "$ctx" delete clusterrole system:kube-vip-role system:kube-vip-cloud-controller-role --ignore-not-found
  kubectl --context "$ctx" -n kube-system delete sa kube-vip kube-vip-cloud-controller --ignore-not-found
done

echo "demo 51 removed (KEPT: eg1/eg2, Envoy Gateway, GatewayClass eg, cert-manager, .tmp/eg-root-ca.crt)"
