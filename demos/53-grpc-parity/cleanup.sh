#!/usr/bin/env bash
# cleanup.sh — remove demo 53's route, app, and grpc-tls leaf from poc2. The https-grpc
# listener stays: it is now part of demo 40's shop-gw (30-gateways-poc2.yaml).
#
#   demos/53-grpc-parity/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
CTX=kind-poc2

echo "== $CTX"
kubectl --context "$CTX" -n shop-edge delete grpcroute grpc --ignore-not-found
kubectl --context "$CTX" -n shop-edge delete ciliumnetworkpolicy grpc --ignore-not-found
kubectl --context "$CTX" -n shop-edge delete deploy grpc --ignore-not-found
kubectl --context "$CTX" -n shop-edge delete svc grpc --ignore-not-found
kubectl --context "$CTX" -n shop-edge delete certificate grpc-tls --ignore-not-found
# cert-manager here runs WITHOUT --enable-certificate-owner-ref (demo 40 measured: the Secret
# has no ownerReferences), so deleting the Certificate leaves its Secret behind.
kubectl --context "$CTX" -n shop-edge delete secret grpc-tls --ignore-not-found

echo "demo 53 removed (KEPT: shop-gw listener https-grpc — it is demo 40's door now; re-apply 20-certificates.yaml to restore grpc-tls)"
