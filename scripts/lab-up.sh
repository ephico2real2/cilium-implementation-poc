#!/usr/bin/env bash
# lab-up.sh — build the lab from nothing: the kind clusters, Cilium 1.20.1 from the lab's values, the Gateway API CRDs,
# the LB pools and the L2 announcement policy, and — when both clusters are asked for — the ClusterMesh between them.
# One script for the CI runner and for a laptop, so docs/SETUP.md and the workflow are one path (enhancement 004).
#
#   scripts/lab-up.sh poc1            # one cluster
#   scripts/lab-up.sh poc1 poc2       # both, meshed
#   LAB_CLUSTERS_DIR=clusters scripts/lab-up.sh poc1 poc2    # the laptop's full-size configs instead of clusters/ci
#
# Idempotent per step: an existing cluster is kept, an installed Cilium is upgraded with the same values. Every wait has
# a deadline and says what it was waiting for. Needs: docker, kind, kubectl, helm, cilium (the CLI).
set -euo pipefail; cd "$(dirname "$0")/.."
CLUSTERS="${LAB_CLUSTERS_DIR:-clusters/ci}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
[ $# -ge 1 ] || { echo "usage: $0 poc1 [poc2]"; exit 2; }
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }

for c in "$@"; do
  say "cluster $c"
  if kind get clusters 2>/dev/null | grep -qx "$c"; then echo "kind cluster $c exists, kept"; else kind create cluster --config "$CLUSTERS/$c.yaml" --wait 0; fi
  # the kind network is where the LB pools live: the lab pins 172.18.255.x, so the subnet must be 172.18.0.0/16
  subnet=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  [ "$subnet" = "172.18.0.0/16" ] || { echo "::error::the kind docker network is $subnet, the lab's pools expect 172.18.0.0/16 (cilium/lb-ippool.yaml)"; exit 1; }
done

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true; helm repo update cilium >/dev/null
first="$1"
for c in "$@"; do
  say "Cilium $CILIUM_VERSION on $c"
  ctx="kind-$c"
  # ClusterMesh needs one CA in both clusters: the second cluster gets the first one's cilium-ca before Cilium is
  # installed (demo 07's CA-mismatch fix, and what Cilium's own conformance-clustermesh workflow does)
  if [ "$c" != "$first" ] && ! kubectl --context "$ctx" -n kube-system get secret cilium-ca >/dev/null 2>&1; then
    kubectl --context "kind-$first" -n kube-system get secret cilium-ca -o yaml | grep -v -E 'resourceVersion|uid:|creationTimestamp' | kubectl --context "$ctx" create -f -
  fi
  # with one control plane there is no load-balancer container: the API server is the control-plane node, by the name
  # that is in its certificate (gotcha #1 — the IP is not)
  host="$c-control-plane"; docker ps --format '{{.Names}}' | grep -qx "$c-external-load-balancer" && host="$c-external-load-balancer"
  helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" \
    -f "cilium/values-$c.yaml" -f cilium/values-ci.yaml --set k8sServiceHost="$host" --set k8sServicePort=6443 --wait --timeout 10m >/dev/null
  cilium status --context "$ctx" --wait --wait-duration 10m --interactive=false | grep -E 'Cilium:|Operator:|KubeProxyReplacement|Cluster Pods' || true
  say "Gateway API $GATEWAY_API_VERSION CRDs, the LB pools and the L2 policy on $c"
  for crd in gatewayclasses gateways httproutes referencegrants grpcroutes backendtlspolicies tlsroutes; do
    kubectl --context "$ctx" apply --server-side -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GATEWAY_API_VERSION/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml" >/dev/null
  done
  kubectl --context "$ctx" apply -f cilium/lb-ippool.yaml >/dev/null
  # Gateway API is switched on after the CRDs exist, as demo 05 does (with ALPN), then the operator rolls once
  helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" --reuse-values \
    --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true --wait --timeout 10m >/dev/null
  cilium status --context "$ctx" --wait --wait-duration 10m --interactive=false >/dev/null
  kubectl --context "$ctx" get ciliumloadbalancerippools -o custom-columns='POOL:.metadata.name,BLOCKS:.spec.blocks[*].start' --no-headers
done

if [ $# -ge 2 ]; then
  say "ClusterMesh: $1 <-> $2"
  for c in "$1" "$2"; do cilium clustermesh enable --context "kind-$c" --service-type NodePort; done
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done
  cilium clustermesh connect --context "kind-$1" --destination-context "kind-$2"
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done
fi
say "lab up: $*"
