#!/usr/bin/env bash
# cleanup.sh — remove demo 54's doors, app, kube-vip and the shop namespace.
# Leaves the eg-poc1 cluster (Envoy Gateway, cert-manager, the lab root).
# Does not touch poc1, poc2, CRC, or the kind network. The cluster itself
# is scripts/eg-down.sh.
#
#   demos/54-eg-poc1-kube-vip/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
CTX=kind-eg-poc1

echo "== $CTX"
kubectl --context "$CTX" -n shop delete httproute --all --ignore-not-found
kubectl --context "$CTX" -n shop delete grpcroute --all --ignore-not-found
kubectl --context "$CTX" -n shop delete gateway --all --ignore-not-found
# The door Services (envoy-gateway-system, owned by the GatewayClass) carry
# service.kubernetes.io/load-balancer-cleanup, which only the cloud-provider
# clears (demo 51 review A1: 66 ms with it running, unbounded with it gone).
# Wait for them to be gone BEFORE the provider goes; no match → exit 0 at once.
for gw in http-gw grpc-gw; do
  kubectl --context "$CTX" -n envoy-gateway-system wait svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$gw" --for=delete --timeout=60s
done
kubectl --context "$CTX" -n shop delete envoyproxy --all --ignore-not-found
kubectl --context "$CTX" -n shop delete certificate eg-poc1-tls --ignore-not-found
kubectl --context "$CTX" -n shop delete secret eg-poc1-tls --ignore-not-found
kubectl --context "$CTX" delete ns shop --ignore-not-found --wait=false
kubectl --context "$CTX" -n kube-system delete deploy kube-vip-cloud-provider --ignore-not-found
kubectl --context "$CTX" -n kube-system delete ds kube-vip-ds --ignore-not-found
kubectl --context "$CTX" -n kube-system delete cm kubevip --ignore-not-found
kubectl --context "$CTX" delete clusterrolebinding system:kube-vip-binding system:kube-vip-cloud-controller-binding --ignore-not-found
kubectl --context "$CTX" delete clusterrole system:kube-vip-role system:kube-vip-cloud-controller-role --ignore-not-found
kubectl --context "$CTX" -n kube-system delete sa kube-vip kube-vip-cloud-controller --ignore-not-found

echo "demo 54 removed (KEPT: eg-poc1, Envoy Gateway, GatewayClass eg, cert-manager, .tmp/eg-poc1-root-ca.crt)"
