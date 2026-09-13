#!/usr/bin/env bash
# lab-up.sh — build the lab from nothing: the kind clusters, Cilium 1.20.1 from the lab's values, the Gateway API CRDs,
# the LB pools and the L2 announcement policy, and — when both clusters are asked for — the ClusterMesh between them.
# One script for the CI runner and for a laptop, so docs/SETUP.md and the workflow are one path (enhancement 004).
#
#   scripts/lab-up.sh poc1            # one cluster
#   scripts/lab-up.sh poc1 poc2       # both, meshed
#   LAB_CLUSTERS_DIR=clusters scripts/lab-up.sh poc1 poc2    # the laptop's full-size configs instead of clusters/ci
#   LAB_FEATURES=1 LAB_IPFAMILY=dual scripts/lab-up.sh poc1 poc2   # + cilium/values-ci-features.yaml (netkit, BBR, BIG TCP,
#                                                                  #   IPv6) and dual-stack kind clusters (enhancement 004)
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
  cfg="$CLUSTERS/$c.yaml"
  if [ "${LAB_IPFAMILY:-ipv4}" = "dual" ]; then
    # dual-stack: the lab's IPv4 ranges plus a ULA range per cluster (poc1 fd00:10::, poc2 fd00:20::); kind puts IPv6
    # on its docker network by itself when the host has it (the runner does)
    n=${c#poc}; cfg=$(mktemp); sed -e "s|podSubnet: \"\(.*\)\"|podSubnet: \"\1,fd00:$n:10::/48\"|" -e "s|serviceSubnet: \"\(.*\)\"|serviceSubnet: \"\1,fd00:$n:11::/112\"|" -e 's|^networking:|networking:\n  ipFamily: dual|' "$CLUSTERS/$c.yaml" > "$cfg"
  fi
  if kind get clusters 2>/dev/null | grep -qx "$c"; then echo "kind cluster $c exists, kept"; else kind create cluster --config "$cfg" --wait 0; fi
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
  # the Gateway API CRDs go in BEFORE Cilium, and Gateway API is switched on in the one install: a Helm change to
  # Cilium's ConfigMap does not roll its pods, so the operator never registered the CRD the agents ask for after a later
  # restart — the first spike run's agents died on "Unable to find all Cilium CRDs … within 5m0s" right after
  # `clustermesh enable` restarted them (run 34784194103). One install, one configuration, nothing to roll.
  say "Gateway API $GATEWAY_API_VERSION CRDs on $c"
  for crd in gatewayclasses gateways httproutes referencegrants grpcroutes backendtlspolicies tlsroutes; do
    kubectl --context "$ctx" apply --server-side -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$GATEWAY_API_VERSION/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml" >/dev/null
  done
  helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" \
    -f "cilium/values-$c.yaml" -f cilium/values-ci.yaml ${LAB_FEATURES:+-f cilium/values-ci-features.yaml} \
    --set k8sServiceHost="$host" --set k8sServicePort=6443 --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true --wait --timeout 10m >/dev/null
  # the status check must be allowed to FAIL the script: the first spike run hid a CrashLoopBackOff behind a `| grep || true`
  cilium status --context "$ctx" --wait --wait-duration 10m --interactive=false > "/tmp/cilium-status-$c.txt" || { cat "/tmp/cilium-status-$c.txt"; echo "::error::Cilium is not healthy on $c"; exit 1; }
  grep -E 'Cilium:|Operator:|KubeProxyReplacement|Cluster Pods' "/tmp/cilium-status-$c.txt"
  say "the LB pools and the L2 policy on $c"
  kubectl --context "$ctx" apply -f cilium/lb-ippool.yaml >/dev/null
  kubectl --context "$ctx" get ciliumloadbalancerippools -o custom-columns='POOL:.metadata.name,BLOCKS:.spec.blocks[*].start' --no-headers
done

if [ $# -ge 2 ]; then
  say "ClusterMesh: $1 <-> $2"
  for c in "$1" "$2"; do cilium clustermesh enable --context "kind-$c" --service-type NodePort; done
  # `clustermesh enable` restarts the agents; wait for the DaemonSet, and say so if it does not come back
  for c in "$1" "$2"; do kubectl --context "kind-$c" -n kube-system rollout status ds/cilium --timeout=5m || { echo "::error::the agents did not come back after clustermesh enable on $c"; kubectl --context "kind-$c" -n kube-system logs ds/cilium -c cilium-agent --tail=30; exit 1; }; done
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done
  cilium clustermesh connect --context "kind-$1" --destination-context "kind-$2"
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done
fi
say "lab up: $*"
