#!/usr/bin/env bash
# cleanup.sh — remove demo 56's BGP doors, routes and grpcdemo; restore
# kube-vip to L2 (clusters/eg/kube-vip-ds.yaml) and wait until demo 54's
# doors answer ARP again (arping .100 3/3). The fabric stays. shopapi,
# shop-db, demo 54's Gateways, the certificate, the cloud-provider and
# eg-poc1 stay. Does not touch poc1, poc2, eg-poc2, CRC, or the kind
# network.
#
#   demos/56-kube-vip-bgp/cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
CTX=kind-eg-poc1
L2_HTTP=172.19.255.100

echo "== $CTX — demo 56 cleanup (fabric stays)"
kubectl --context "$CTX" -n shop delete httproute shop-api-bgp --ignore-not-found
kubectl --context "$CTX" -n shop delete grpcroute orders-bgp --ignore-not-found
kubectl --context "$CTX" -n shop delete gateway bgp-http-gw bgp-grpc-gw --ignore-not-found
# Door Services carry service.kubernetes.io/load-balancer-cleanup, which
# only the cloud-provider clears (demo 54 review A3). Wait BEFORE
# anything else changes kube-vip. No match → exit 0 at once.
for gw in bgp-http-gw bgp-grpc-gw; do
  kubectl --context "$CTX" -n envoy-gateway-system wait svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$gw" --for=delete --timeout=60s
done
kubectl --context "$CTX" -n shop delete envoyproxy bgp-http-gw-proxy bgp-grpc-gw-proxy --ignore-not-found
kubectl --context "$CTX" -n shop delete deploy grpcdemo-v1 grpcdemo-v2 --ignore-not-found
kubectl --context "$CTX" -n shop delete svc grpc-v1 grpc-v2 --ignore-not-found

echo "== restore clusters/eg/kube-vip-ds.yaml (L2 mode)"
kubectl --context "$CTX" apply -f clusters/eg/kube-vip-ds.yaml
kubectl --context "$CTX" -n kube-system rollout status ds/kube-vip-ds --timeout=180s

echo "== wait for demo 54's doors to be announced (arping $L2_HTTP 3/3)"
replies=0
for i in $(seq 1 30); do
  out=$(docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -b -c 3 -I eth0 "$L2_HTTP" 2>&1 || true)
  replies=$(printf '%s\n' "$out" | grep -c 'Unicast reply' || true)
  echo "arping $L2_HTTP attempt $i: replies=$replies"
  if [ "$replies" -eq 3 ]; then
    break
  fi
  sleep 3
done
if [ "$replies" -ne 3 ]; then
  echo "cleanup.sh: demo 54 door $L2_HTTP not announced after restore (replies=$replies)" >&2
  exit 1
fi

echo "demo 56 removed (KEPT: fabric, eg-poc1, demo 54 doors/app/cert, kube-vip L2, .tmp/eg-poc1-root-ca.crt)"
