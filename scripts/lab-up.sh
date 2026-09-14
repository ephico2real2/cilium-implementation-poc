#!/usr/bin/env bash
# lab-up.sh — build the lab from nothing, in DEPENDENCY order, so the CI runner and a laptop take one path and every
# step names the chapter of docs/SETUP.md or the demo it comes from (enhancement 004).
#
#   scripts/lab-up.sh poc1                 # one cluster, complete
#   scripts/lab-up.sh poc1 poc2            # both, each complete on its own, then meshed on cert-manager's root
#   LAB_CLUSTERS_DIR=clusters scripts/lab-up.sh poc1 poc2         # the laptop's full-size configs instead of clusters/ci
#   LAB_FEATURES=1 LAB_IPFAMILY=dual scripts/lab-up.sh poc1 poc2  # + cilium/values-ci-features.yaml (netkit, IPv6)
#   LAB_TETRAGON=0 / LAB_CERTMANAGER=0                          # skip demo 17 / Helm's certificates (SETUP 9.3b, route B)
#
# THE ORDER IS A DEPENDENCY ORDER, NOT THE DEMOS' LESSON ORDER. The demos were built in stages on purpose, to teach; a
# lab built for testing does the right thing: what a component needs must exist before it is deployed, and each cluster
# is made fully functional on its own before anything crosses clusters. What must exist before what:
#
#   component                       needs                                                       chapter
#   the kind docker network         nothing — created FIRST, with the subnet the pools are pinned to SETUP 3.5.1, 8
#   the Gateway API CRDs            a cluster, nothing else                                     demo 05
#   Cilium core (CNI, KPR, GW API)  those CRDs, the API endpoint by the name in its certificate SETUP 4, 5, 6
#   CoreDNS upstreams               the CNI (pods with a network)                               kind on a runner
#   the LB pools + the L2 policy    Cilium's CRDs, registered by the operator; the cluster's OWN   SETUP 8, NETWORKING_DESIGN §0
#                                   /26 of the reserved range (cilium/lb-ippool-<cluster>.yaml)
#   metrics-server                  the CNI                                                     HPA (002), the sysdump
#   cert-manager, the root, issuer  the CNI; the FIRST cluster's root for every other cluster   SETUP 9.3a, demo 08
#   Hubble (relay, UI, metrics)     the pools (its UI's address), the issuer (its certificates) SETUP 5.4, demos 01/24/25
#   Tetragon                        the CNI, the /procHost mount, the host kernel symbol        demo 17
#   ---- a cluster is complete and independent here; nothing above knows a peer exists --------------------------------
#   the mesh apiserver, declared    EVERY cluster complete; the issuer (its certificates); one  SETUP 9.4, demo 24
#                                   root shared; every member's address known (all created first)
#   the mesh verified               every apiserver up — the link is pairwise, checked last     SETUP 9.5, demo 07
#
# cluster_up runs the whole column for one cluster and verifies each layer before the next; mesh_up runs once, after
# every cluster is complete ("we need both clusters up and independent before creating or running clustermesh steps"
# — the operator, 2026-09-14). Every wait has a deadline; a failed layer prints its evidence and stops the run.
# Idempotent: an existing cluster is kept, an installed release is upgraded with the same values.
set -euo pipefail; cd "$(dirname "$0")/.."
CLUSTERS="${LAB_CLUSTERS_DIR:-clusters/ci}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"             # SETUP Step 5
KIND_VERSION_WANT="${KIND_VERSION_WANT:-0.33.0}"        # SETUP Step 1.1
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"    # demo 05 (vendored under crds/)
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.1}" # demo 08 / SETUP Step 9.3a
TETRAGON_VERSION="${TETRAGON_VERSION:-1.7.1}"           # demo 17
METRICS_SERVER_CHART="${METRICS_SERVER_CHART:-3.14.0}"  # metrics-server 0.9.0
[ $# -ge 1 ] || { echo "usage: $0 poc1 [poc2 …]"; exit 2; }
first="$1"; mesh=$([ $# -ge 2 ] && echo 1 || echo 0); certmanager="${LAB_CERTMANAGER:-1}"
say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)"; }
die() { echo "::error::$1"; exit 1; }
evidence() { # <ctx> — what to print when a Cilium layer fails
  kubectl --context "$1" -n kube-system get pods -o wide | grep -E 'cilium|hubble|clustermesh' || true
  kubectl --context "$1" -n kube-system logs ds/cilium -c cilium-agent --tail=15 2>/dev/null | grep -E 'level=(error|fatal)' | tail -5 || true
}
cilium_healthy() { # <cluster> <what> — SETUP Step 6.1, reused after every change to Cilium
  cilium status --context "kind-$1" --wait --wait-duration 10m --interactive=false > "/tmp/cilium-status-$1.txt" \
    || { cat "/tmp/cilium-status-$1.txt"; evidence "kind-$1"; die "Cilium is not healthy on $1 $2"; }
}

# ================================================================ SETUP Step 0 / 1 — the requisites, measured
say "SETUP Step 0–1 — the toolchain, as the guide inventories it"
for t in docker kind kubectl helm cilium python3 openssl; do command -v "$t" >/dev/null || die "$t is not installed (SETUP Step 1)"; done
kv=$(kind version | awk '{print $2}' | sed 's/^v//'); [ "$kv" = "$KIND_VERSION_WANT" ] || echo "::warning::kind $kv, the guide pins $KIND_VERSION_WANT"
printf 'kind %s | kubectl %s | helm %s | cilium-cli %s | docker %s | kernel %s\n' "$kv" \
  "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')" \
  "$(helm version --short)" "$(cilium version --client 2>/dev/null | grep -m1 -oE 'v?[0-9]+\.[0-9]+\.[0-9]+')" "$(docker version --format '{{.Server.Version}}')" "$(uname -r)"
# what THIS host can run, measured before anything is created (SETUP Steps 0–2; the same table on the runner and a Mac)
LAB_PREFLIGHT_STRICT=1 CILIUM_VERSION="$CILIUM_VERSION" scripts/lab-preflight.sh || die "preflight failed (the table above says which row; SETUP Steps 1–2)"
for c in "$@"; do [ -f "$CLUSTERS/$c.yaml" ] || die "no cluster config $CLUSTERS/$c.yaml"; done
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true                                  # SETUP Step 5.1
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true                              # demo 08
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update cilium jetstack metrics-server >/dev/null

# ================================================================ the kind docker network, with the lab's subnet — before any cluster
# kind reuses a docker network named `kind` if one exists and, when it creates one itself, passes NO IPv4 subnet
# (pkg/cluster/internal/providers/docker/network.go, v0.33.0: bridge driver, masquerade, the MTU, a hashed IPv6 ULA)
# — Docker's IPAM then picks any free pool. The lab's LB blocks (cilium/lb-ippool-<cluster>.yaml) and its Gateway addresses
# are pinned to 172.18.255.x (SETUP Step 8, gotcha #13), so the network is created here with that subnet, and with
# Docker's container allocation held to the lower half (--ip-range) so no container can ever take a pool address.
# The IPv6 subnet is the one kind derives for the name "kind", so dual-stack runs are identical either way.
LAB_SUBNET="${LAB_SUBNET:-172.18.0.0/16}"; LAB_IP_RANGE="${LAB_IP_RANGE:-172.18.0.0/17}"; LAB_SUBNET6="${LAB_SUBNET6:-fc00:f853:ccd:e793::/64}"
say "the kind docker network: $LAB_SUBNET (containers from $LAB_IP_RANGE, the pools above it), IPv6 $LAB_SUBNET6"
if docker network inspect kind >/dev/null 2>&1; then
  have=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
  [ "$have" = "$LAB_SUBNET" ] || die "a docker network 'kind' exists with subnet $have, not $LAB_SUBNET — delete it (no cluster must be on it) or set LAB_SUBNET and the pools to match"
  echo "exists with $have, kept"
else
  mtu=$(docker network inspect bridge --format '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null); [ -n "$mtu" ] || mtu=1500
  docker network create -d bridge --subnet "$LAB_SUBNET" --ip-range "$LAB_IP_RANGE" --gateway "${LAB_SUBNET%.*.*}.0.1" \
    -o com.docker.network.bridge.enable_ip_masquerade=true -o com.docker.network.driver.mtu="$mtu" --ipv6 --subnet "$LAB_SUBNET6" kind >/dev/null
  echo "created: $(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')"
fi

# ================================================================ SETUP Step 3 / 9.1 — every cluster first: the mesh declaration (demo 24) needs every control plane's IP
cluster_create() {
  local c="$1" cfg n
  say "SETUP Step $( [ "$c" = "$first" ] && echo 3 || echo 9.1 ) — create $c (kind, no CNI, no kube-proxy, the lab's CIDRs)"
  cfg="$CLUSTERS/$c.yaml"
  if [ "${LAB_IPFAMILY:-ipv4}" = "dual" ]; then   # the lab's IPv4 ranges plus a ULA range per cluster (poc1 fd00:1:…, poc2 fd00:2:…)
    n=${c#poc}; cfg=$(mktemp)
    sed -e "s|podSubnet: \"\(.*\)\"|podSubnet: \"\1,fd00:$n:10::/48\"|" -e "s|serviceSubnet: \"\(.*\)\"|serviceSubnet: \"\1,fd00:$n:11::/112\"|" -e 's|^networking:|networking:\n  ipFamily: dual|' "$CLUSTERS/$c.yaml" > "$cfg"
  fi
  if kind get clusters 2>/dev/null | grep -qx "$c"; then echo "kind cluster $c exists, kept"; else kind create cluster --config "$cfg" --wait 0; fi
}
cp_ip() { docker inspect "$1-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }   # demo 24: the address the other clusters reach the mesh apiserver at (NodePort 32379)

# ================================================================ one cluster, complete
cluster_up() {
  local c="$1" ctx="kind-$1" host ip
  # ---------------------------------------------------------------- demo 05 — the Gateway API CRDs, before Cilium
  say "demo 05 — Gateway API $GATEWAY_API_VERSION CRDs on $c (vendored: crds/gateway-api)"
  GATEWAY_API_VERSION="$GATEWAY_API_VERSION" scripts/gateway-api-crds.sh "$ctx"

  # ---------------------------------------------------------------- SETUP Step 4 — the API server endpoint, by the name in its certificate
  host="$c-control-plane"; docker ps --format '{{.Names}}' | grep -qx "$c-external-load-balancer" && host="$c-external-load-balancer"
  echo "SETUP Step 4 — k8sServiceHost=$host"
  if [ "$c" != "$first" ] && [ "$certmanager" != "1" ] && ! kubectl --context "$ctx" -n kube-system get secret cilium-ca >/dev/null 2>&1; then
    # SETUP Step 9.3b, route B only: one Helm CA everywhere — copied BEFORE Cilium is installed (the chart reuses it)
    kubectl --context "kind-$first" -n kube-system get secret cilium-ca -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "Opaque"), "metadata": {"name": "cilium-ca", "namespace": "kube-system"}, "data": s["data"]}))' | kubectl --context "$ctx" apply -f - >/dev/null
    echo "SETUP Step 9.3b — cilium-ca copied from $first"
  fi

  # ---------------------------------------------------------------- SETUP Step 5 / 9.2 — Cilium's CORE (Hubble comes when its needs exist)
  say "SETUP Step $( [ "$c" = "$first" ] && echo 5 || echo 9.2 ) — Cilium $CILIUM_VERSION core on $c (cilium/values-$c.yaml + values-ci.yaml)"
  helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" \
    -f "cilium/values-$c.yaml" -f cilium/values-ci.yaml ${LAB_FEATURES:+-f cilium/values-ci-features.yaml} \
    --set k8sServiceHost="$host" --set k8sServicePort=6443 --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true \
    --set hubble.enabled=false --set hubble.relay.enabled=false --set hubble.ui.enabled=false >/dev/null \
    || die "Helm refused the Cilium install on $c (SETUP Step 5)"
  # (the chart's validate.yaml refuses a relay or a UI without hubble.enabled — run 34790879335 — so all three are off
  #  here; the Hubble step below re-applies the lab's values file, which carries them as the lab wants them)

  # ---------------------------------------------------------------- SETUP Step 6 — verify the core before anything is built on it
  say "SETUP Step 6 — verify $c: Cilium's own status, the nodes Ready, kube-proxy replaced"
  cilium_healthy "$c" "(SETUP Step 6.1)"; grep -E 'Cilium:|Operator:|Cluster Pods' "/tmp/cilium-status-$c.txt"
  kubectl --context "$ctx" wait node --all --for=condition=Ready --timeout=5m >/dev/null && echo "Step 6.2 — nodes Ready"
  kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null | grep -E 'KubeProxyReplacement:' | sed 's/^/Step 6.3 — /'
  kubectl --context "$ctx" -n kube-system get ds kube-proxy >/dev/null 2>&1 && die "a kube-proxy DaemonSet exists on $c (SETUP Step 6.3)" || echo "Step 6.3 — no kube-proxy DaemonSet"

  # ---------------------------------------------------------------- CoreDNS on kind: an upstream a pod can reach (Docker's 127.0.0.11 is the node's loopback)
  say "CoreDNS on $c — explicit upstream resolvers"
  kubectl --context "$ctx" -n kube-system patch deployment coredns --patch '{"spec":{"template":{"spec":{"dnsPolicy":"None","dnsConfig":{"nameservers":["8.8.4.4","8.8.8.8"]}}}}}' >/dev/null
  kubectl --context "$ctx" -n kube-system rollout status deploy/coredns --timeout=3m >/dev/null
  # Captured, then searched — piped straight into `grep -m1`, kubectl's later writes hit a closed pipe, its exit code
  # became the pipeline's under pipefail, and the warning fired beside a good answer (run 34792046715:
  # "external name resolved: Address: 1.0.0.1" followed by the warning). Retried, because CoreDNS was just rolled and
  # one probe landed before its new endpoints served (run 34792046715, base: no answer at all, 16 s after the roll).
  # A layer that is verified prints its evidence or stops the run: the raw probe output on failure, then die.
  local dns="" ok=0 i
  for i in 1 2 3 4 5 6; do
    dns=$(kubectl --context "$ctx" run "dns-probe-$c-$i" --rm -i --restart=Never --image=busybox:1.36 --command -- nslookup one.one.one.one 2>&1 || true)
    if printf '%s\n' "$dns" | grep -qE 'Address: [0-9]'; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" = 1 ]; then echo "external name resolved (probe $i): $(printf '%s\n' "$dns" | grep -m1 -E 'Address: [0-9]')"
  else printf '%s\n' "$dns" | sed 's/^/  probe: /'; die "pods on $c cannot resolve an external name after $i probes (CoreDNS upstreams — the layer every FQDN demo needs)"; fi

  # ---------------------------------------------------------------- SETUP Step 8 — LoadBalancer addresses without a cloud
  say "SETUP Step 8 — $c's OWN LB block and its L2 announcement policy (cilium/lb-ippool-$c.yaml)"
  # one /26 of 172.18.255.0/24 per cluster: every cluster announces on the same bridge, and LB IPAM allocates per
  # cluster — one pool file for two clusters would hand out the same address twice (NETWORKING_DESIGN §0)
  [ -f "cilium/lb-ippool-$c.yaml" ] || die "no cilium/lb-ippool-$c.yaml — every cluster has its own block of the reserved range (NETWORKING_DESIGN §0)"
  kubectl --context "$ctx" apply -f "cilium/lb-ippool-$c.yaml" >/dev/null
  kubectl --context "$ctx" get ciliumloadbalancerippools -o custom-columns='POOL:.metadata.name,START:.spec.blocks[*].start,STOP:.spec.blocks[*].stop' --no-headers

  # ---------------------------------------------------------------- metrics-server
  say "metrics-server $METRICS_SERVER_CHART on $c (kind's kubelets: --kubelet-insecure-tls)"
  helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_SERVER_CHART" --namespace kube-system --kube-context "$ctx" \
    --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m >/dev/null

  # ---------------------------------------------------------------- SETUP Step 9.3a / demo 08 — cert-manager, the root once, the same issuer everywhere
  if [ "$certmanager" = "1" ]; then
    say "SETUP Step 9.3a / demo 08 — cert-manager $CERT_MANAGER_VERSION on $c$( [ "$c" = "$first" ] && echo ', the root' || echo ", the root copied from $first" ), ClusterIssuer/ca-issuer"
    helm upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" --namespace cert-manager --create-namespace \
      --kube-context "$ctx" --set crds.enabled=true --wait --timeout 5m >/dev/null
    if [ "$c" = "$first" ]; then
      kubectl --context "$ctx" apply -f demos/08-certmanager-ca/01-root-ca-poc1.yaml >/dev/null
      kubectl --context "$ctx" -n cert-manager wait certificate/clustermesh-root-ca --for=condition=Ready --timeout=2m >/dev/null
    else
      # demo 08 Part 3: only the CA Secret crosses; the object is rebuilt so that exactly name, namespace, type and data survive
      kubectl --context "kind-$first" -n cert-manager get secret clustermesh-root-ca -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "kubernetes.io/tls"),
  "metadata": {"name": s["metadata"]["name"], "namespace": "cert-manager"}, "data": s["data"]}))' | kubectl --context "$ctx" apply -f - >/dev/null
      kubectl --context "$ctx" apply -f demos/08-certmanager-ca/02-issuer-poc2.yaml >/dev/null
    fi
    kubectl --context "$ctx" wait clusterissuer/ca-issuer --for=condition=Ready --timeout=2m >/dev/null
    echo "root CA $(kubectl --context "$ctx" -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)… issuer Ready"
  fi

  # ---------------------------------------------------------------- Hubble (SETUP 5.4, demos 01/24/25) and the mesh apiserver (demo 24), on what now exists
  say "Hubble on $c — one upgrade on the verified core; certificates from $( [ "$certmanager" = 1 ] && echo 'ClusterIssuer/ca-issuer' || echo 'Helm')"
  # the lab's values file carries relay, UI and metrics as the lab wants them (Step 5 had switched them off with the core)
  # shellcheck disable=SC2046
  helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "$ctx" --reuse-values \
    -f "cilium/values-$c.yaml" --set hubble.enabled=true $( [ "$certmanager" = 1 ] && echo "-f cilium/values-ci-certmanager.yaml" ) --wait --timeout 10m >/dev/null \
    || { evidence "$ctx"; die "Helm could not enable Hubble on $c"; }
  [ "$certmanager" = 1 ] && kubectl --context "$ctx" -n kube-system wait certificate --all --for=condition=Ready --timeout=3m >/dev/null
  # Hubble lives in the agent's ConfigMap: a Helm change there rolls nothing by itself (gotcha #97) — restart, then wait
  kubectl --context "$ctx" -n kube-system rollout restart ds/cilium >/dev/null
  kubectl --context "$ctx" -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
  kubectl --context "$ctx" -n kube-system rollout status deploy/hubble-relay --timeout=5m >/dev/null
  cilium_healthy "$c" "with Hubble"
  grep -E 'Hubble Relay:' "/tmp/cilium-status-$c.txt" | head -1
  if kubectl --context "$ctx" -n kube-system get svc hubble-ui >/dev/null 2>&1; then
    for i in $(seq 1 24); do ip=$(kubectl --context "$ctx" -n kube-system get svc hubble-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); [ -n "$ip" ] && break; sleep 5; done
    echo "hubble-ui LoadBalancer: ${ip:-NO ADDRESS after 2 minutes} (SETUP Step 8: give Hubble UI a real address, from $c's own block)"
  fi
  [ "$certmanager" = 1 ] && kubectl --context "$ctx" -n kube-system get certificate -o custom-columns='CERTIFICATE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ISSUER:.spec.issuerRef.name' --no-headers

  # ---------------------------------------------------------------- demo 17 — Tetragon, on the finished cluster
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
  say "$c is complete and independent — Cilium, DNS, its own LB block, metrics-server, its issuer, Hubble, Tetragon; no mesh yet"
}

# ================================================================ the mesh — a phase on COMPLETE clusters, never inside one
mesh_up() { # <cluster…> — SETUP Step 9.4 (demo 24's declarative form), then Step 9.5
  say "SETUP Step 9.4 / demo 24 — the mesh on complete clusters ($*): the apiserver on and every member declared, one upgrade per cluster"
  if [ "$certmanager" = 1 ]; then   # demo 08 Part 3: one trust anchor — the fingerprints compared, not assumed
    local fps; fps=$(for c in "$@"; do kubectl --context "kind-$c" -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; done | sort -u | wc -l | tr -d ' ')
    [ "$fps" = "1" ] || die "the clusters do not share one root CA ($fps distinct fingerprints; demo 08 Part 3)"
    echo "root CA fingerprint identical in $# clusters"
  fi
  # What `cilium clustermesh enable` sets, as Helm values (cilium-cli clustermesh.go: useAPIServer AND config.enabled — the
  # apiserver's users ConfigMap is rendered only with config.enabled, gotcha #96), plus the NodePort kind needs. On one
  # root every member is declared by name, address and port — demo 24's clusters.yaml from live state; "Cilium ignores
  # the local cluster from the list of remote clusters", so the same list is right in every cluster, and the
  # declaration IS the connection. On route B the CLI's `connect` writes the list, with each peer's own CA.
  local declared="--set clustermesh.useAPIServer=true --set clustermesh.apiserver.service.type=NodePort --set clustermesh.config.enabled=true" c i=0
  if [ "$certmanager" = 1 ]; then
    for c in "$@"; do declared="$declared --set clustermesh.config.clusters[$i].name=$c --set clustermesh.config.clusters[$i].ips[0]=$(cp_ip "$c") --set clustermesh.config.clusters[$i].port=32379"; i=$((i+1)); done
  else
    declared="$declared --set clustermesh.apiserver.tls.auto.method=helm"
  fi
  for c in "$@"; do
    # shellcheck disable=SC2046,SC2086
    helm upgrade cilium cilium/cilium --version "$CILIUM_VERSION" --namespace kube-system --kube-context "kind-$c" --reuse-values \
      -f "cilium/values-$c.yaml" $( [ "$certmanager" = 1 ] && echo "-f cilium/values-ci-certmanager.yaml" ) $declared --wait --timeout 10m >/dev/null \
      || { evidence "kind-$c"; die "Helm could not switch the mesh apiserver on in $c (SETUP Step 9.4)"; }
    [ "$certmanager" = 1 ] && kubectl --context "kind-$c" -n kube-system wait certificate --all --for=condition=Ready --timeout=3m >/dev/null
    echo "$c: mesh apiserver on, $# members declared$( [ "$certmanager" = 1 ] && echo ', certificates Ready from ClusterIssuer/ca-issuer' )"
  done
  # the agents read the mesh at start: restarted only now, when every apiserver exists (gotcha #92 was this check too early)
  for c in "$@"; do
    kubectl --context "kind-$c" -n kube-system rollout restart ds/cilium >/dev/null
    kubectl --context "kind-$c" -n kube-system rollout status ds/cilium --timeout=5m >/dev/null
    kubectl --context "kind-$c" -n kube-system rollout status deploy/clustermesh-apiserver --timeout=5m >/dev/null
  done
  if [ "$certmanager" != 1 ]; then
    for c in "$@"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 5m; done
    for c in "${@:2}"; do cilium clustermesh connect --context "kind-$1" --destination-context "kind-$c"; done
  fi
  say "SETUP Step 9.5 — verify the mesh (connecting ≠ connected): every cluster healthy with every peer's apiserver up, then the mesh"
  for c in "$@"; do cilium_healthy "$c" "with the mesh (every peer's apiserver up — SETUP 9.5)"; echo "$c: $(grep -E 'ClusterMesh:' "/tmp/cilium-status-$c.txt" | head -1 | tr -s ' ')"; done
  for c in "$@"; do cilium clustermesh status --context "kind-$c" --wait --wait-duration 10m; done
}

for c in "$@"; do cluster_create "$c"; done   # every cluster exists first: its address is part of the declaration
for c in "$@"; do cluster_up "$c"; done       # each complete and independent, in turn
[ "$mesh" = 1 ] && mesh_up "$@"              # only then the mesh, on all of them
say "lab up: $*"
