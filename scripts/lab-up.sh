#!/usr/bin/env bash
# lab-up.sh — build the lab from nothing, in the guide's order: docs/SETUP.md step by step, then the demo chapters that
# add to the base (05 Gateway API, 08 cert-manager root, 07/24 ClusterMesh on the enterprise CA, 17 Tetragon), so the
# CI runner and a laptop take one path and every step names the chapter it comes from (enhancement 004).
#
#   scripts/lab-up.sh poc1                 # one cluster (SETUP Steps 0–8b, demos 05, 08, 17)
#   scripts/lab-up.sh poc1 poc2            # both, meshed on cert-manager's root (SETUP Step 9 route A, demos 07, 08, 24)
#   LAB_CLUSTERS_DIR=clusters scripts/lab-up.sh poc1 poc2         # the laptop's full-size configs instead of clusters/ci
#   LAB_FEATURES=1 LAB_IPFAMILY=dual scripts/lab-up.sh poc1 poc2  # + cilium/values-ci-features.yaml (netkit, BBR, IPv6)
#   LAB_TETRAGON=0 / LAB_CERTMANAGER=0                          # skip demo 17 / keep Helm's certificates (route B)
#
# Idempotent per step: an existing cluster is kept, an installed release is upgraded with the same values. Every wait
# has a deadline and says what it was waiting for; a failed step prints the evidence and stops the run.
set -euo pipefail; cd "$(dirname "$0")/.."
CLUSTERS="${LAB_CLUSTERS_DIR:-clusters/ci}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"            # SETUP Step 5
KIND_VERSION_WANT="${KIND_VERSION_WANT:-0.33.0}"       # SETUP Step 1.1
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"   # demo 05 (vendored under crds/)
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.1}" # demo 08 / SETUP Step 9.3a
TETRAGON_VERSION="${TETRAGON_VERSION:-1.7.1}"          # demo 17
METRICS_SERVER_CHART="${METRICS_SERVER_CHART:-3.14.0}" # metrics-server 0.9.0 (HPA, enhancement 002; the sysdump's usage collectors)
[ $# -ge 1 ] || { echo "usage: $0 poc1 [poc2]"; exit 2; }
first="$1"
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "::error::$1"; exit 1; }

# ---------------------------------------------------------------- SETUP Step 0 / Step 1 — the requisites, measured
say "SETUP Step 0–1 — the toolchain, as the guide inventories it"
for t in docker kind kubectl helm cilium python3 openssl; do command -v "$t" >/dev/null || die "$t is not installed (SETUP Step 1)"; done
kv=$(kind version | awk '{print $2}' | sed 's/^v//'); [ "$kv" = "$KIND_VERSION_WANT" ] || echo "::warning::kind $kv, the guide pins $KIND_VERSION_WANT"
printf 'kind %s | kubectl %s | helm %s | cilium-cli %s | docker %s | kernel %s\n' "$kv" "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')" "$(helm version --short)" "$(cilium version --client 2>/dev/null | grep -m1 -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' )" "$(docker version --format '{{.Server.Version}}')" "$(uname -r)"
docker info >/dev/null 2>&1 || die "the Docker daemon is not answering (SETUP Step 1.4)"
for c in "$@"; do [ -f "$CLUSTERS/$c.yaml" ] || die "no cluster config $CLUSTERS/$c.yaml"; done

# ---------------------------------------------------------------- SETUP Step 3 / 9.1 — the clusters
for c in "$@"; do
  say "SETUP Step $( [ "$c" = "$first" ] && echo 3 || echo 9.1 ) — create $c (kind, no CNI, no kube-proxy, the lab's CIDRs)"
  cfg="$CLUSTERS/$c.yaml"
  if [ "${LAB_IPFAMILY:-ipv4}" = "dual" ]; then
    # dual-stack: the lab's IPv4 ranges plus a ULA range per cluster (poc1 fd00:1:…, poc2 fd00:2:…)
    n=${c#poc}; cfg=$(mktemp)
    sed -e "s|podSubnet: \"\(.*\)\"|podSubnet: \"\1,fd00:$n:10::/48\"|" -e "s|serviceSubnet: \"\(.*\)\"|serviceSubnet: \"\1,fd00:$n:11::/112\"|" -e 's|^networking:|networking:\n  ipFamily: dual|' "$CLUSTERS/$c.yaml" > "$cfg"
  fi
  if kind get clusters 2>/dev/null | grep -qx "$c"; then echo "kind cluster $c exists, kept"; else kind create cluster --config "$cfg" --wait 0; fi
  # SETUP Step 8: the pools are pinned to the kind network's subnet (gotcha #13)
  subnet=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  [ "$subnet" = "172.18.0.0/16" ] || die "the kind docker network is $subnet; the lab's pools expect 172.18.0.0/16 (cilium/lb-ippool.yaml, SETUP Step 8)"
done

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true; helm repo update cilium >/dev/null   # SETUP Step 5.1

for c in "$@"; do
  ctx="kind-$c"
  # ---------------------------------------------------------------- demo 05 — the Gateway API CRDs go in before Cilium
  # A Helm change to Cilium's ConfigMap rolls nothing, so the operator never registered the CRD the agents asked for
  # after a later restart (run 34784194103): Gateway API is on from the first install, the CRDs are here first.
  say "demo 05 — Gateway API $GATEWAY_API_VERSION CRDs on $c (vendored: crds/gateway-api)"
  GATEWAY_API_VERSION="$GATEWAY_API_VERSION" scripts/gateway-api-crds.sh "$ctx"

  # ---------------------------------------------------------------- SETUP Step 4 — the API server endpoint Cilium must use
  # with one control plane there is no load-balancer container: the API server is the control-plane node, by the NAME
  # that is in its certificate (SETUP Step 5.3: the IP is not)
  host="$c-control-plane"; docker ps --format '{{.Names}}' | grep -qx "$c-external-load-balancer" && host="$c-external-load-balancer"
  echo "SETUP Step 4 — k8sServiceHost=$host"

  # ---------------------------------------------------------------- SETUP Step 5 / 9.2 — Cilium, from the lab's values
  say "SETUP Step $( [ "$c" = "$first" ] && echo 5 || echo 9.2 ) — Cilium $CILIUM_VERSION on $c (cilium/values-$c.yaml + values-ci.yaml)"
  # SETUP Step 9.3b, route B only: one Helm CA in both clusters — the second cluster gets the first one's cilium-ca
  # BEFORE Cilium is installed (the chart reuses an existing secret). Route A replaces every certificate with
  # cert-manager's afterwards, so it does not need this.
  if [ "$c" != "$first" ] && [ "${LAB_CERTMANAGER:-1}" != "1" ] && ! kubectl --context "$ctx" -n kube-system get secret cilium-ca >/dev/null 2>&1; then
    kubectl --context "kind-$first" -n kube-system get secret cilium-ca -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "Opaque"), "metadata": {"name": "cilium-ca", "namespace": "kube-system"}, "data": s["data"]}))' | kubectl --context "$ctx" apply -f - >/dev/null
    echo "SETUP Step 9.3b — cilium-ca copied from $first"
  fi
  helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" \
    -f "cilium/values-$c.yaml" -f cilium/values-ci.yaml ${LAB_FEATURES:+-f cilium/values-ci-features.yaml} \
    --set k8sServiceHost="$host" --set k8sServicePort=6443 --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true --wait --timeout 10m >/dev/null

  # ---------------------------------------------------------------- SETUP Step 6 — verify the install
  say "SETUP Step 6 — verify $c: Cilium's own status, the nodes Ready, kube-proxy replaced"
  cilium status --context "$ctx" --wait --wait-duration 10m --interactive=false > "/tmp/cilium-status-$c.txt" || { cat "/tmp/cilium-status-$c.txt"; die "Cilium is not healthy on $c (SETUP Step 6.1)"; }
  grep -E 'Cilium:|Operator:|Cluster Pods' "/tmp/cilium-status-$c.txt"
  kubectl --context "$ctx" wait node --all --for=condition=Ready --timeout=5m >/dev/null && echo "nodes Ready (Step 6.2)"
  kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E 'KubeProxyReplacement:' | sed 's/^/Step 6.3 — /'

  # ---------------------------------------------------------------- CoreDNS on kind: an upstream a pod can reach
  # A kind node's /etc/resolv.conf names Docker's embedded DNS, 127.0.0.11 — the node's loopback, unreachable from
  # CoreDNS's pod namespace, so every external name times out ("Resolving timed out after 2001 milliseconds", ten
  # connectivity-test failures in run 34787222878). cilium/cilium's own kind workflow gives the CoreDNS pods explicit
  # public resolvers (dnsPolicy None); so does the lab.
  say "CoreDNS on $c: explicit upstream resolvers (Docker's 127.0.0.11 is not reachable from a pod)"
  kubectl --context "$ctx" -n kube-system patch deployment coredns --patch '{"spec":{"template":{"spec":{"dnsPolicy":"None","dnsConfig":{"nameservers":["8.8.4.4","8.8.8.8"]}}}}}' >/dev/null
  kubectl --context "$ctx" -n kube-system rollout status deploy/coredns --timeout=3m >/dev/null
  kubectl --context "$ctx" run dns-probe-"$c" --rm -i --restart=Never --image=busybox:1.36 --command -- nslookup one.one.one.one 2>/dev/null | grep -m1 -E 'Address: [0-9]' | sed 's/^/external name resolved: /' || echo "::warning::external name resolution from a pod still fails on $c"

  # ---------------------------------------------------------------- SETUP Step 8 — LoadBalancer addresses without a cloud
  say "SETUP Step 8 — the LB pools and the L2 announcement policy on $c"
  kubectl --context "$ctx" apply -f cilium/lb-ippool.yaml >/dev/null
  kubectl --context "$ctx" get ciliumloadbalancerippools -o custom-columns='POOL:.metadata.name,BLOCKS:.spec.blocks[*].start' --no-headers

  # ---------------------------------------------------------------- metrics-server (new in CI; HPA in 002, the sysdump's usage collectors)
  say "metrics-server $METRICS_SERVER_CHART on $c (kind's kubelets: --kubelet-insecure-tls)"
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true; helm repo update metrics-server >/dev/null
  helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_SERVER_CHART" --namespace kube-system --kube-context "$ctx" \
    --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m >/dev/null
  kubectl --context "$ctx" top nodes 2>/dev/null | head -3 || echo "(metrics.k8s.io not serving yet — the first scrape takes a minute)"

  # ---------------------------------------------------------------- demo 17 — Tetragon
  if [ "${LAB_TETRAGON:-1}" = "1" ]; then
    say "demo 17 — Tetragon $TETRAGON_VERSION on $c"
    # blocker 1 of demo 17: the base sensor needs security_bprm_committing_creds (CONFIG_SECURITY); a kind node shares
    # the host kernel, so the host is checked. blocker 2, the /procHost mount, is in clusters/ci/*.yaml.
    if [ -r /proc/kallsyms ] && ! grep -q ' security_bprm_committing_creds$' /proc/kallsyms; then
      die "the kernel $(uname -r) has no security_bprm_committing_creds: Tetragon's base sensor cannot load (demo 17, blocker 1)"
    fi
    helm upgrade --install tetragon cilium/tetragon --version "$TETRAGON_VERSION" --namespace kube-system --kube-context "$ctx" \
      -f demos/17-tetragon/values-tetragon.yaml -f cilium/values-tetragon-ci.yaml --wait --timeout 5m >/dev/null
    kubectl --context "$ctx" -n kube-system rollout status ds/tetragon --timeout=5m >/dev/null || { kubectl --context "$ctx" -n kube-system logs ds/tetragon -c tetragon --tail=20; die "Tetragon's agents did not become ready on $c (demo 17)"; }
    kubectl --context "$ctx" -n kube-system exec ds/tetragon -c tetragon -- tetra status 2>/dev/null | head -3 || true
  fi
done

# ---------------------------------------------------------------- SETUP Step 9.3a / demo 08 — trust BEFORE connecting: route A, the enterprise root
if [ "${LAB_CERTMANAGER:-1}" = "1" ]; then
  say "SETUP Step 9.3a / demo 08 — cert-manager $CERT_MANAGER_VERSION in every cluster, the root once in $first, the same issuer everywhere"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true; helm repo update jetstack >/dev/null
  for c in "$@"; do
    helm upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" --namespace cert-manager --create-namespace \
      --kube-context "kind-$c" --set crds.enabled=true --wait --timeout 5m >/dev/null
  done
  kubectl --context "kind-$first" apply -f demos/08-certmanager-ca/01-root-ca-poc1.yaml >/dev/null
  kubectl --context "kind-$first" -n cert-manager wait certificate/clustermesh-root-ca --for=condition=Ready --timeout=2m >/dev/null
  for c in "$@"; do
    if [ "$c" != "$first" ]; then
      # demo 08 Part 3: only the CA Secret crosses; the object is rebuilt so that exactly name, namespace, type and data survive
      kubectl --context "kind-$first" -n cert-manager get secret clustermesh-root-ca -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "kubernetes.io/tls"),
  "metadata": {"name": s["metadata"]["name"], "namespace": "cert-manager"}, "data": s["data"]}))' | kubectl --context "kind-$c" apply -f - >/dev/null
      kubectl --context "kind-$c" apply -f demos/08-certmanager-ca/02-issuer-poc2.yaml >/dev/null
    fi
    kubectl --context "kind-$c" wait clusterissuer/ca-issuer --for=condition=Ready --timeout=2m >/dev/null
  done
  # demo 08 Part 3: one trust anchor — the fingerprints compared, not assumed
  fps=$(for c in "$@"; do kubectl --context "kind-$c" -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; done | sort -u | wc -l | tr -d ' ')
  [ "$fps" = "1" ] || die "the clusters do not share one root CA ($fps distinct fingerprints; demo 08 Part 3)"
  echo "root CA fingerprint identical in $# cluster(s)"

  # ---------------------------------------------------------------- SETUP Step 21 / demo 24 — every certificate consumer on the issuer
  say "demo 24 — Cilium on the issuer: Hubble's certificates$( [ $# -ge 2 ] && echo ' and the mesh apiserver') from ClusterIssuer/ca-issuer"
  for c in "$@"; do
    ctx="kind-$c"; mesh=""; [ $# -ge 2 ] && mesh="--set clustermesh.useAPIServer=true --set clustermesh.apiserver.service.type=NodePort"
    # shellcheck disable=SC2086
    helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" --reuse-values \
      -f cilium/values-ci-certmanager.yaml $mesh --wait --timeout 10m >/dev/null
    kubectl --context "$ctx" -n kube-system wait certificate --all --for=condition=Ready --timeout=3m >/dev/null
    # a Helm change to a ConfigMap or a Secret rolls nothing by itself (run 34784194103): the agents and the relay are
    # restarted here, explicitly, and waited for — what `cilium` CLI does after its own upgrades
    kubectl --context "$ctx" -n kube-system rollout restart ds/cilium deploy/hubble-relay >/dev/null
    kubectl --context "$ctx" -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
    kubectl --context "$ctx" -n kube-system rollout status deploy/hubble-relay --timeout=5m >/dev/null
    cilium status --context "$ctx" --wait --wait-duration 10m --interactive=false > "/tmp/cilium-status-$c.txt" || { cat "/tmp/cilium-status-$c.txt"; die "Cilium is not healthy on $c after the cert-manager switch (demo 24)"; }
    kubectl --context "$ctx" -n kube-system get certificate -o custom-columns='CERTIFICATE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ISSUER:.spec.issuerRef.name' --no-headers
  done
elif [ $# -ge 2 ]; then
  # SETUP Step 9.3b — route B: Helm's certificates, one CA copied (already done before the second install), the mesh apiserver
  say "SETUP Step 9.3b — route B: the mesh apiserver on Helm's certificates"
  for c in "$@"; do
    helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "kind-$c" --reuse-values \
      --set clustermesh.useAPIServer=true --set clustermesh.apiserver.service.type=NodePort --set clustermesh.apiserver.tls.auto.method=helm --wait --timeout 10m >/dev/null
  done
fi

# ---------------------------------------------------------------- SETUP Step 9.4 / 9.5 — connect, then verify (connecting ≠ connected)
if [ $# -ge 2 ]; then
  say "SETUP Step 9.4 — ClusterMesh: $1 <-> $2 (connect only — the apiservers are installed)"
  for c in "$1" "$2"; do kubectl --context "kind-$c" -n kube-system rollout status deploy/clustermesh-apiserver --timeout=5m >/dev/null; done
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 5m; done
  cilium clustermesh connect --context "kind-$1" --destination-context "kind-$2"
  say "SETUP Step 9.5 — verify the mesh"
  for c in "$1" "$2"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done
fi
say "lab up: $*"
