#!/usr/bin/env bash
# cleanup.sh — remove demo 52's doors, app, MetalLB and the shop namespace.
# Leaves the eg-poc2 cluster (Envoy Gateway, cert-manager, the lab root).
# Does not touch poc1, poc2, CRC, or the kind network. The cluster itself
# is scripts/eg-down.sh.
#
# The door Services carry service.kubernetes.io/load-balancer-cleanup, which
# only MetalLB clears. Wait for them to be gone BEFORE helm uninstall
# (demo 54 review A3: deleting the LB first leaves Services Terminating).
# The pools go BEFORE the uninstall too: the chart templates its CRDs.
#
#   demos/52-eg-poc2-metallb/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
CTX=kind-eg-poc2

echo "== $CTX"
kubectl --context "$CTX" -n shop delete httproute --all --ignore-not-found
kubectl --context "$CTX" -n shop delete grpcroute --all --ignore-not-found
kubectl --context "$CTX" -n shop delete gateway --all --ignore-not-found
# Wait for the door Services to be gone (--for=delete) BEFORE helm uninstall.
for gw in http-gw grpc-gw; do
  kubectl --context "$CTX" -n envoy-gateway-system wait svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$gw" --for=delete --timeout=60s
done
kubectl --context "$CTX" -n shop delete envoyproxy --all --ignore-not-found
kubectl --context "$CTX" -n shop delete certificate eg-poc2-tls --ignore-not-found
kubectl --context "$CTX" -n shop delete secret eg-poc2-tls --ignore-not-found
kubectl --context "$CTX" delete ns shop --ignore-not-found --wait=false
# Empty the pools BEFORE helm uninstall. Chart 0.16.0 templates its nine CRDs
# (helm show crds: none; helm get manifest: 9, no helm.sh/resource-policy keep),
# so the uninstall removes them, and a delete of a type the server no longer has
# is exit 1 ("the server doesn't have a resource type") — --ignore-not-found does
# not cover it. Skip when the CRD is absent (second run, never installed).
if kubectl --context "$CTX" get crd ipaddresspools.metallb.io -o name >/dev/null 2>&1; then
  kubectl --context "$CTX" -n metallb-system delete l2advertisement --all --ignore-not-found
  kubectl --context "$CTX" -n metallb-system delete ipaddresspool --all --ignore-not-found
fi
helm uninstall metallb -n metallb-system --kube-context "$CTX" || true
kubectl --context "$CTX" delete ns metallb-system --ignore-not-found --wait=false

echo "demo 52 removed (KEPT: eg-poc2, Envoy Gateway, GatewayClass eg, cert-manager, .tmp/eg-poc2-root-ca.crt)"
