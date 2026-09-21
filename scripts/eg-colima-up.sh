#!/usr/bin/env bash
# eg-colima-up.sh — THE GUIDE for the Colima vanilla cluster (enhancement 008,
# demo 54c). The node LAN, the local registry, one kind cluster
# (eg-poc1-colima) with kindnet + kube-proxy, no Cilium, no Envoy Gateway.
# Images come from kind-registry — no kind load.
#
# Every docker call is --context "$CTX" (the fabric-colima-lib.sh gate).
# kind talks to that daemon via DOCKER_HOST; kubeconfig is a dedicated
# file under $HOME. Never desktop-linux, never the Desktop fabric.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env

TRANSCRIPT="${EG_COLIMA_TRANSCRIPT:-demos/54-eg-poc1-kube-vip-colima/output/transcript.txt}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")" "$(dirname "$EG_COLIMA_KUBECONFIG")"

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi
if ! fabric_colima_require_ctx; then
  exit 1
fi

fabric_colima_save_ctx
trap fabric_colima_restore_ctx EXIT

if ! fabric_colima_kind_env; then
  exit 1
fi

rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
say() { printf '\n== %s  (%s)\n' "$1" "$(date -u +%H:%M:%SZ)"; }
die() { echo "eg-colima-up: $1" >&2; exit 1; }

{
  echo
  echo "=== eg-colima-up.sh start $(date -u +%Y-%m-%dT%H:%M:%SZ) cluster=$EG_COLIMA_CLUSTER ctx=$CTX ==="
  echo "=== kindnet + kube-proxy iptables; no Cilium; no Envoy Gateway ==="
  echo "=== DOCKER_HOST=$DOCKER_HOST KIND_EXPERIMENTAL_DOCKER_NETWORK=$KIND_EXPERIMENTAL_DOCKER_NETWORK ==="
  echo "=== kubeconfig=$KUBECONFIG ==="
} | tee -a "$TRANSCRIPT"

# ---------------------------------------------------------------- (1) the node LAN
say "1. the $KIND_EG_COLIMA_NET network ($KIND_EG_COLIMA_SUBNET, ip-range $KIND_EG_COLIMA_IP_RANGE)"
fabric_colima_ensure_kind_net | tee -a "$TRANSCRIPT"
rec docker --context "$CTX" network inspect "$KIND_EG_COLIMA_NET" \
  --format '{{range .IPAM.Config}}subnet={{.Subnet}} ip-range={{.IPRange}} gateway={{.Gateway}}{{"\n"}}{{end}}'

# ---------------------------------------------------------------- (2) the registry
say "2. local registry kind-registry on 127.0.0.1:${KIND_REGISTRY_PORT}"
rec scripts/colima-registry.sh up

# ---------------------------------------------------------------- (3) the cluster
assert_node_ips() {
  # every IPv4 InternalIP must sit in the lower /17; none in .254/24 or .255/24
  export KIND_EG_COLIMA_IP_RANGE KIND_EG_COLIMA_SUBNET
  kubectl --context "kind-$EG_COLIMA_CLUSTER" get nodes -o json | python3 -c '
import ipaddress, json, os, sys
low = ipaddress.ip_network(os.environ["KIND_EG_COLIMA_IP_RANGE"])
net = ipaddress.ip_network(os.environ["KIND_EG_COLIMA_SUBNET"])
# .254/24 (leaves) and .255/24 (reserved L2 VIP) of this /16
prefix = int(net.network_address) & 0xFFFF0000
routers = ipaddress.ip_network("%s/24" % ipaddress.ip_address(prefix + (254 << 8)))
vips = ipaddress.ip_network("%s/24" % ipaddress.ip_address(prefix + (255 << 8)))
doc = json.load(sys.stdin)
bad = []
n_v4 = 0
for n in doc["items"]:
    name = n["metadata"]["name"]
    for a in n.get("status", {}).get("addresses", []):
        if a.get("type") != "InternalIP":
            continue
        ip = ipaddress.ip_address(a["address"])
        if ip.version != 4:
            continue
        n_v4 += 1
        print("%s %s" % (name, ip))
        if ip not in low:
            bad.append("%s %s not in %s" % (name, ip, low))
        if ip in routers:
            bad.append("%s %s is in %s (routers)" % (name, ip, routers))
        if ip in vips:
            bad.append("%s %s is in %s (reserved VIP)" % (name, ip, vips))
if n_v4 == 0:
    sys.exit("no IPv4 InternalIP on any node")
if bad:
    sys.exit("; ".join(bad))
'
}

say "3. cluster $EG_COLIMA_CLUSTER on $KIND_EG_COLIMA_NET (kindnet + kube-proxy iptables; no Cilium)"
if kind get clusters 2>/dev/null | grep -qx "$EG_COLIMA_CLUSTER"; then
  echo "kind cluster $EG_COLIMA_CLUSTER exists, kept"
else
  rec env KIND_EXPERIMENTAL_DOCKER_NETWORK="$KIND_EG_COLIMA_NET" \
    DOCKER_HOST="$DOCKER_HOST" \
    kind create cluster \
    --name "$EG_COLIMA_CLUSTER" \
    --kubeconfig "$KUBECONFIG" \
    --config clusters/eg-poc1-colima.yaml \
    --image "$KIND_NODE_IMAGE"
fi
rec kubectl --context "kind-$EG_COLIMA_CLUSTER" wait --for=condition=Ready nodes --all --timeout=180s
rec kubectl --context "kind-$EG_COLIMA_CLUSTER" get nodes -o wide
if ! ips=$(assert_node_ips); then
  printf '%s\n' "$ips" | tee -a "$TRANSCRIPT"
  die "$EG_COLIMA_CLUSTER: a node IP is outside $KIND_EG_COLIMA_IP_RANGE or inside a reserved /24"
fi
{
  echo "node IPv4 InternalIPs (must be in $KIND_EG_COLIMA_IP_RANGE, none in 172.20.254.0/24 or 172.20.255.0/24):"
  printf '%s\n' "$ips"
} | tee -a "$TRANSCRIPT"

# docker-side check: nodes landed on kind-eg-colima, not the default `kind`
for node in $(kind get nodes --name "$EG_COLIMA_CLUSTER"); do
  net_ip=$(docker --context "$CTX" inspect -f \
    "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" "$node" 2>/dev/null || true)
  if [ -z "$net_ip" ] || [ "$net_ip" = "<no value>" ]; then
    die "$node is not on $KIND_EG_COLIMA_NET"
  fi
  echo "$node docker $KIND_EG_COLIMA_NET=$net_ip" | tee -a "$TRANSCRIPT"
done

rec kubectl --context "kind-$EG_COLIMA_CLUSTER" -n kube-system get ds kindnet kube-proxy
rec bash -c "kubectl --context kind-$EG_COLIMA_CLUSTER -n kube-system get cm kube-proxy -o yaml | grep -E '^[[:space:]]*mode:'"

# ---------------------------------------------------------------- (4) registry hosts.toml + ConfigMap
say "4. containerd hosts.toml for localhost:${KIND_REGISTRY_PORT} + local-registry-hosting ConfigMap"
# shellcheck disable=SC2329
registry_hosts() {
  set -euo pipefail
  local node dir
  dir="/etc/containerd/certs.d/localhost:${KIND_REGISTRY_PORT}"
  for node in $(kind get nodes --name "$EG_COLIMA_CLUSTER"); do
    docker --context "$CTX" exec "$node" mkdir -p "$dir"
    docker --context "$CTX" exec -i "$node" tee "$dir/hosts.toml" >/dev/null <<EOF
[host."http://${KIND_REGISTRY_NAME}:5000"]
EOF
    echo "wrote $dir/hosts.toml on $node"
  done
}
export -f registry_hosts
export CTX EG_COLIMA_CLUSTER KIND_REGISTRY_PORT KIND_REGISTRY_NAME
rec bash -c registry_hosts
unset -f registry_hosts

rec bash -c "kubectl --context kind-$EG_COLIMA_CLUSTER apply -f -" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${KIND_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "eg-colima-up: done. cluster $EG_COLIMA_CLUSTER on $KIND_EG_COLIMA_NET; kubeconfig $KUBECONFIG" | tee -a "$TRANSCRIPT"
