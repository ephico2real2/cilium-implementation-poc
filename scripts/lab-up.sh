#!/usr/bin/env bash
# lab-up.sh — build the lab from nothing: the kind clusters, Cilium 1.20.1 from the lab's values, the Gateway API CRDs,
# the LB pools and the L2 announcement policy, and — when both clusters are asked for — the ClusterMesh between them.
# One script for the CI runner and for a laptop, so docs/SETUP.md and the workflow are one path (enhancement 004).
#
#   scripts/lab-up.sh poc1            # one cluster
#   scripts/lab-up.sh poc1 poc2       # both, meshed
#   LAB_CLUSTERS_DIR=clusters scripts/lab-up.sh poc1 poc2    # the laptop's full-size configs instead of clusters/ci
#   LAB_TETRAGON=0 scripts/lab-up.sh poc1                      # without Tetragon (demo 17; on by default)
#   LAB_CERTMANAGER=0 scripts/lab-up.sh poc1 poc2               # Helm's certificates instead of cert-manager's root (demos 08/24; on by default)
#   LAB_FEATURES=1 LAB_IPFAMILY=dual scripts/lab-up.sh poc1 poc2   # + cilium/values-ci-features.yaml (netkit, BBR, BIG TCP,
#                                                                  #   IPv6) and dual-stack kind clusters (enhancement 004)
#
# Idempotent per step: an existing cluster is kept, an installed Cilium is upgraded with the same values. Every wait has
# a deadline and says what it was waiting for. Needs: docker, kind, kubectl, helm, cilium (the CLI).
set -euo pipefail; cd "$(dirname "$0")/.."
CLUSTERS="${LAB_CLUSTERS_DIR:-clusters/ci}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
TETRAGON_VERSION="${TETRAGON_VERSION:-1.7.1}"      # demo 17; LAB_TETRAGON=0 skips it
METRICS_SERVER_CHART="${METRICS_SERVER_CHART:-3.14.0}"   # metrics-server 0.9.0
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.1}"  # demos 08 and 24; LAB_CERTMANAGER=0 keeps Helm's certificates
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
  say "Gateway API $GATEWAY_API_VERSION CRDs on $c (vendored, crds/gateway-api)"
  GATEWAY_API_VERSION="$GATEWAY_API_VERSION" scripts/gateway-api-crds.sh "$ctx"
  # The mesh comes later, on cert-manager's root (demos 08 and 24): cert-manager's pods need a CNI, so the order is
  # Cilium (Helm certificates, no mesh) → cert-manager → the root and the issuer → one upgrade that turns the mesh
  # apiserver on with both TLS blocks on the issuer → connect. `cilium clustermesh enable` is not used: it ran a
  # certgen Job and restarted the agents, and its status poll printed "Trying to get secret … by deprecated name"
  # until the Job had run (runs 34784194103–34787222878).
  helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" \
    -f "cilium/values-$c.yaml" -f cilium/values-ci.yaml ${LAB_FEATURES:+-f cilium/values-ci-features.yaml} \
    --set k8sServiceHost="$host" --set k8sServicePort=6443 --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true --wait --timeout 10m >/dev/null
  # the status check must be allowed to FAIL the script: the first spike run hid a CrashLoopBackOff behind a `| grep || true`
  cilium status --context "$ctx" --wait --wait-duration 10m --interactive=false > "/tmp/cilium-status-$c.txt" || { cat "/tmp/cilium-status-$c.txt"; echo "::error::Cilium is not healthy on $c"; exit 1; }
  grep -E 'Cilium:|Operator:|KubeProxyReplacement|Cluster Pods' "/tmp/cilium-status-$c.txt"
  say "the LB pools and the L2 policy on $c"
  kubectl --context "$ctx" apply -f cilium/lb-ippool.yaml >/dev/null
  kubectl --context "$ctx" get ciliumloadbalancerippools -o custom-columns='POOL:.metadata.name,BLOCKS:.spec.blocks[*].start' --no-headers
  # metrics-server: the lab never had one (HPA in enhancement 002 needs it; `cilium sysdump` collects node and pod
  # usage from metrics.k8s.io and warned without it). kind's kubelets serve self-signed certificates: --kubelet-insecure-tls.
  say "metrics-server $METRICS_SERVER_CHART on $c"
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true; helm repo update metrics-server >/dev/null
  helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_SERVER_CHART" --namespace kube-system --kube-context "$ctx" \
    --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m >/dev/null
  kubectl --context "$ctx" top nodes 2>/dev/null | head -3 || echo "(metrics.k8s.io not serving yet — the first scrape takes a minute)"
  # Tetragon (demo 17) — the runtime-security agent the lab's sysdumps and demo 17 expect. Its base sensor needs the
  # kernel symbol security_bprm_committing_creds (CONFIG_SECURITY); the laptop's linuxkit kernel had none, a Linux
  # runner does. A kind node shares the host kernel, so the check is on the host.
  if [ "${LAB_TETRAGON:-1}" = "1" ]; then
    say "Tetragon $TETRAGON_VERSION on $c"
    if [ -r /proc/kallsyms ] && ! grep -q ' security_bprm_committing_creds$' /proc/kallsyms; then
      echo "::error::the kernel $(uname -r) has no security_bprm_committing_creds (CONFIG_SECURITY): Tetragon's base sensor cannot load (demo 17, blocker 1)"; exit 1
    fi
    helm upgrade --install tetragon cilium/tetragon --version "$TETRAGON_VERSION" --namespace kube-system --kube-context "$ctx" \
      -f demos/17-tetragon/values-tetragon.yaml -f cilium/values-tetragon-ci.yaml --wait --timeout 5m >/dev/null
    kubectl --context "$ctx" -n kube-system rollout status ds/tetragon --timeout=5m || { echo "::error::Tetragon's agents did not become ready on $c"; kubectl --context "$ctx" -n kube-system logs ds/tetragon -c tetragon --tail=20; exit 1; }
    kubectl --context "$ctx" -n kube-system exec ds/tetragon -c tetragon -- tetra status 2>/dev/null | head -3 || true
  fi
done

if [ "${LAB_CERTMANAGER:-1}" = "1" ]; then
  say "cert-manager $CERT_MANAGER_VERSION, the root in $first, the same issuer everywhere (demos 08 and 24)"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true; helm repo update jetstack >/dev/null
  for c in "$@"; do
    helm upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" --namespace cert-manager --create-namespace \
      --kube-context "kind-$c" --set crds.enabled=true --wait --timeout 5m >/dev/null
  done
  kubectl --context "kind-$first" apply -f demos/08-certmanager-ca/01-root-ca-poc1.yaml >/dev/null
  kubectl --context "kind-$first" -n cert-manager wait certificate/clustermesh-root-ca --for=condition=Ready --timeout=2m >/dev/null
  for c in "$@"; do
    if [ "$c" != "$first" ]; then
      # only the CA Secret crosses; the object is rebuilt so that exactly name, namespace, type and data survive (demo 08 Part 3)
      kubectl --context "kind-$first" -n cert-manager get secret clustermesh-root-ca -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "kubernetes.io/tls"),
  "metadata": {"name": s["metadata"]["name"], "namespace": "cert-manager"}, "data": s["data"]}))' | kubectl --context "kind-$c" apply -f - >/dev/null
      kubectl --context "kind-$c" apply -f demos/08-certmanager-ca/02-issuer-poc2.yaml >/dev/null
    fi
    kubectl --context "kind-$c" wait clusterissuer/ca-issuer --for=condition=Ready --timeout=2m >/dev/null
  done
  # one trust anchor: the fingerprints must be identical, measured, not assumed
  fps=$(for c in "$@"; do kubectl --context "kind-$c" -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; done | sort -u | wc -l | tr -d ' ')
  [ "$fps" = "1" ] || { echo "::error::the clusters do not share one root CA ($fps distinct fingerprints)"; exit 1; }
  echo "root CA fingerprint identical in $# cluster(s)"

  say "Cilium on the issuer: Hubble's certificates$( [ $# -ge 2 ] && echo ' and the mesh apiserver') from cert-manager"
  for c in "$@"; do
    ctx="kind-$c"; mesh=""; [ $# -ge 2 ] && mesh="--set clustermesh.useAPIServer=true --set clustermesh.apiserver.service.type=NodePort"
    # shellcheck disable=SC2086
    helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" --reuse-values \
      -f cilium/values-ci-certmanager.yaml $mesh --wait --timeout 10m >/dev/null
    kubectl --context "$ctx" -n kube-system wait certificate --all --for=condition=Ready --timeout=3m >/dev/null
    # a Helm change to the ConfigMap or a Secret rolls nothing by itself (the CRD trap of run 34784194103): the agents,
    # the relay and the mesh apiserver are restarted here, explicitly, and waited for
    kubectl --context "$ctx" -n kube-system rollout restart ds/cilium deploy/hubble-relay >/dev/null
    kubectl --context "$ctx" -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
    kubectl --context "$ctx" -n kube-system rollout status deploy/hubble-relay --timeout=5m >/dev/null
    cilium status --context "$ctx" --wait --wait-duration 10m --interactive=false > "/tmp/cilium-status-$c.txt" || { cat "/tmp/cilium-status-$c.txt"; echo "::error::Cilium is not healthy on $c after the cert-manager switch"; exit 1; }
    kubectl --context "$ctx" -n kube-system get certificate -o custom-columns='CERTIFICATE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ISSUER:.spec.issuerRef.name' --no-headers
  done
fi

if [ $# -ge 2 ]; then
  say "ClusterMesh: $1 <-> $2 (connect only — the apiservers are installed)"
  for c in "$1" "$2"; do kubectl --context "kind-$c" -n kube-system rollout status deploy/clustermesh-apiserver --timeout=5m >/dev/null; done
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 5m; done
  cilium clustermesh connect --context "kind-$1" --destination-context "kind-$2"
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done
fi
say "lab up: $*"
