#!/usr/bin/env bash
# eg-up.sh — THE GUIDE for the vanilla Envoy Gateway lab (enhancement 007 phase 1, demo 50).
# The network, both clusters, the three-command Envoy Gateway install, GatewayClass eg,
# cert-manager, and the shared lab root. Nothing else: no load balancers, no Gateways,
# no apps — those are demos 51 (kube-vip) and 52 (MetalLB).
#
#   scripts/eg-up.sh           # both clusters (default)
#   scripts/eg-up.sh eg1 eg2   # same
#   scripts/eg-up.sh eg1       # one cluster
#
# Idempotent. Every applied command is recorded through scripts/record.sh into
# demos/50-eg-clusters/output/transcript.txt (append, never truncate). Linux-runner
# safe: no macOS-only commands. Reads scripts/bootstrap/versions-eg.env.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env

# The lab root (D8) is minted ONCE, on ROOT_HOME, and every other cluster copies its
# Secret — whatever this invocation's argument list is. `eg-up.sh eg2` after eg1 exists
# must copy eg1's root, never mint a second one; and eg1 is always processed first so a
# two-cluster run has the root before the copy.
ROOT_HOME=eg1
want_eg1=0; want_eg2=0
if [ $# -eq 0 ]; then
  set -- eg1 eg2
fi
for c in "$@"; do
  case "$c" in
    eg1) want_eg1=1 ;;
    eg2) want_eg2=1 ;;
    *) echo "usage: $0 [eg1 eg2]" >&2; exit 2 ;;
  esac
done
set --
[ "$want_eg1" -eq 1 ] && set -- eg1
[ "$want_eg2" -eq 1 ] && set -- "$@" eg2

export RECORD_STRICT=1
TRANSCRIPT=demos/50-eg-clusters/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")" .tmp
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

say() { printf '\n== %s  (%s)\n' "$1" "$(date -u +%H:%M:%SZ)"; }

die() { echo "eg-up: $1" >&2; exit 1; }

# helm, three tries: a chart repository's transient refusal is not the lab's failure
# (same shape as scripts/lab-up.sh helm_r).
helm_r() {
  local i out
  for i in 1 2 3; do
    if out=$(helm "$@" 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
    case "$out" in
      *"connection reset"*|*"TLS handshake timeout"*|*"i/o timeout"*|*"EOF"*|*"503"*|*"502"*)
        echo "  helm: transient ($(printf '%s' "$out" | tail -1 | cut -c1-90)) — try $((i + 1)) of 3 in 15 s" >&2
        sleep 15
        ;;
      *)
        printf '%s\n' "$out" >&2
        return 1
        ;;
    esac
  done
  printf '%s\n' "$out" >&2
  return 1
}
export -f helm_r

{
  echo
  echo "=== eg-up.sh start $(date -u +%Y-%m-%dT%H:%M:%SZ) clusters=$* ==="
  echo "=== THIS SCRIPT STOPS AT THE CONTROLLER, THE GATEWAYCLASS, CERT-MANAGER AND THE LAB ROOT ==="
  echo "=== no load balancers, no Gateways, no apps — those are demos 51 (kube-vip) and 52 (MetalLB) ==="
  echo "=== pins: GATEWAY_API=$GATEWAY_API_VERSION ENVOY_GATEWAY=$ENVOY_GATEWAY_VERSION CERT_MANAGER=$CERT_MANAGER_VERSION ==="
} | tee -a "$TRANSCRIPT"

# ---------------------------------------------------------------- (1) the network
say "1. the kind-eg network (scripts/eg-net.sh — create if absent)"
rec scripts/eg-net.sh
rec docker network inspect kind-eg --format '{{range .IPAM.Config}}subnet={{.Subnet}} ip-range={{.IPRange}} gateway={{.Gateway}}{{"\n"}}{{end}}'

# ---------------------------------------------------------------- (2) each cluster
assert_node_ips() {
  # every IPv4 InternalIP must sit in 172.19.0.0/17; none in 172.19.255.0/24 (R1 / §3.1)
  local ctx=$1
  kubectl --context "$ctx" get nodes -o json | python3 -c '
import ipaddress, json, sys
low = ipaddress.ip_network("172.19.0.0/17")
top = ipaddress.ip_network("172.19.255.0/24")
doc = json.load(sys.stdin)
bad = []
for n in doc["items"]:
    name = n["metadata"]["name"]
    for a in n.get("status", {}).get("addresses", []):
        if a.get("type") != "InternalIP":
            continue
        ip = ipaddress.ip_address(a["address"])
        if ip.version != 4:
            continue
        print("%s %s" % (name, ip))
        if ip not in low:
            bad.append("%s %s not in 172.19.0.0/17" % (name, ip))
        if ip in top:
            bad.append("%s %s is in 172.19.255.0/24 (reserved)" % (name, ip))
if not any(True for n in doc["items"] for a in n.get("status", {}).get("addresses", [])
           if a.get("type") == "InternalIP" and ":" not in a["address"]):
    sys.exit("no IPv4 InternalIP on any node")
if bad:
    sys.exit("; ".join(bad))
'
}

for c in "$@"; do
  ctx="kind-$c"
  say "2. cluster $c on kind-eg (kindnet + kube-proxy iptables; no Cilium)"
  if kind get clusters 2>/dev/null | grep -qx "$c"; then
    echo "kind cluster $c exists, kept"
  else
    rec env KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-eg kind create cluster \
      --config "clusters/$c.yaml" --image "$KIND_NODE_IMAGE"
  fi
  rec kubectl --context "$ctx" wait --for=condition=Ready nodes --all --timeout=180s
  rec kubectl --context "$ctx" get nodes -o wide
  if ! ips=$(assert_node_ips "$ctx"); then
    printf '%s\n' "$ips" | tee -a "$TRANSCRIPT"
    die "$c: a node IP is outside 172.19.0.0/17 or inside 172.19.255.0/24"
  fi
  { echo "node IPv4 InternalIPs (must be in 172.19.0.0/17, none in 172.19.255.0/24):"; printf '%s\n' "$ips"; } | tee -a "$TRANSCRIPT"
  rec kubectl --context "$ctx" -n kube-system get ds kindnet kube-proxy
  rec bash -c "kubectl --context $ctx -n kube-system get cm kube-proxy -o yaml | grep -E '^[[:space:]]*mode:'"
done

# ---------------------------------------------------------------- jetstack once (cert-manager, step 7)
rec helm_r repo add jetstack https://charts.jetstack.io --force-update
rec helm_r repo update jetstack

# ---------------------------------------------------------------- (3)–(7) per cluster
for c in "$@"; do
  ctx="kind-$c"

  # (3) Gateway API standard-channel CRDs from upstream's release YAML.
  # Client-side apply is what phase 0 measured (docs/EG-PHASE0.md R0.3). Server-side
  # apply is the form Kubernetes recommends for CRDs (avoids the last-applied-configuration
  # annotation size cap). We use server-side --force-conflicts so a rerun succeeds if the
  # CRDs were previously applied client-side (phase 0) or by Helm. The URL is the same
  # standard-install.yaml phase 0 applied.
  say "3. Gateway API $GATEWAY_API_VERSION standard-channel CRDs on $c (D5, D10)"
  rec kubectl --context "$ctx" apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  rec bash -c "
set -euo pipefail
n=\$(kubectl --context $ctx get crd -o name | grep -c '\\.gateway\\.networking\\.k8s\\.io\$' || true)
echo \"gateway.networking.k8s.io CRDs: \$n (want 10)\"
[ \"\$n\" -eq 10 ] || { echo \"D10: expected 10 Gateway API CRDs, got \$n\" >&2; exit 1; }
fail=0
while read -r crd; do
  ch=\$(kubectl --context $ctx get \"\$crd\" -o jsonpath='{.metadata.annotations.gateway\\.networking\\.k8s\\.io/channel}')
  ver=\$(kubectl --context $ctx get \"\$crd\" -o jsonpath='{.metadata.annotations.gateway\\.networking\\.k8s\\.io/bundle-version}')
  echo \"\$crd channel=\$ch bundle-version=\$ver\"
  if [ \"\$ch\" != standard ] || [ \"\$ver\" != \"$GATEWAY_API_VERSION\" ]; then
    echo \"D10 FAIL: \$crd channel=\$ch bundle-version=\$ver (want channel=standard bundle-version=$GATEWAY_API_VERSION)\" >&2
    fail=1
  fi
done < <(kubectl --context $ctx get crd -o name | grep '\\.gateway\\.networking\\.k8s\\.io\$')
exit \$fail
"

  # (4) Envoy Gateway's own CRDs from the vendor CRD chart, in the form the vendor
  # prescribes (https://gateway.envoyproxy.io/docs/install/install-helm/):
  # "We're using helm template piped into kubectl apply instead of helm install
  # due to a known Helm limitation (helm/helm#12277) related to large CRDs".
  # A Helm release of this chart is impossible at v1.9.1: its release Secret
  # exceeds Kubernetes' 1 MiB (measured, demo 50 transcript 22:42:21Z), so
  # `helm list` shows the controller only.
  say "4. Envoy Gateway $ENVOY_GATEWAY_VERSION CRDs on $c (gateway-crds-helm, gatewayAPI off; helm template | kubectl apply --server-side)"
  rec bash -c "helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version $ENVOY_GATEWAY_VERSION --set crds.gatewayAPI.enabled=false --set crds.envoyGateway.enabled=true | kubectl --context $ctx apply --server-side --force-conflicts -f -"
  rec bash -c "
set -euo pipefail
n=\$(kubectl --context $ctx get crd -o name | grep -c '\\.gateway\\.envoyproxy\\.io\$' || true)
echo \"gateway.envoyproxy.io CRDs: \$n (want 8)\"
kubectl --context $ctx get crd -o name | grep '\\.gateway\\.envoyproxy\\.io\$'
[ \"\$n\" -eq 8 ] || { echo \"expected 8 gateway.envoyproxy.io CRDs, got \$n\" >&2; exit 1; }
"

  # (5) the controller — crds.enabled=false (its only switch is all-or-nothing; phase 0 item 2)
  say "5. Envoy Gateway controller $ENVOY_GATEWAY_VERSION on $c (crds.enabled=false)"
  rec helm_r upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$ENVOY_GATEWAY_VERSION" -n envoy-gateway-system --create-namespace \
    --kube-context "$ctx" --set crds.enabled=false
  rec kubectl --context "$ctx" -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s

  # (6) GatewayClass — the chart does not create it (phase 0 item 3)
  say "6. GatewayClass eg on $c"
  rec kubectl --context "$ctx" apply -f clusters/eg/gatewayclass.yaml
  rec kubectl --context "$ctx" wait --for=condition=Accepted gatewayclass/eg --timeout=60s

  # (7) cert-manager (lab-up.sh form: helm, crds.enabled=true) and the lab root
  say "7. cert-manager $CERT_MANAGER_VERSION on $c$( [ "$c" = "$ROOT_HOME" ] && echo ', the root' || echo ", the root copied from $ROOT_HOME" ), ClusterIssuer/eg-ca-issuer"
  rec helm_r upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager --create-namespace --kube-context "$ctx" \
    --set crds.enabled=true --wait --timeout 5m
  rec kubectl --context "$ctx" -n cert-manager wait deploy --all --for=condition=Available --timeout=180s
  if [ "$c" = "$ROOT_HOME" ]; then
    rec kubectl --context "$ctx" apply -f clusters/eg/eg-root-ca.yaml
    rec kubectl --context "$ctx" -n cert-manager wait certificate/eg-root-ca --for=condition=Ready --timeout=120s
  else
    # never mint here: the copy needs ROOT_HOME's Secret to exist (D8 — one root for the lab)
    kubectl --context "kind-$ROOT_HOME" -n cert-manager get secret eg-root-ca -o name >/dev/null 2>&1 \
      || die "$c: the lab root lives in $ROOT_HOME and kind-$ROOT_HOME has no Secret cert-manager/eg-root-ca — run scripts/eg-up.sh $ROOT_HOME first"
    rec bash -c "kubectl --context kind-$ROOT_HOME -n cert-manager get secret eg-root-ca -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({\"apiVersion\": \"v1\", \"kind\": \"Secret\", \"type\": s.get(\"type\", \"kubernetes.io/tls\"),
  \"metadata\": {\"name\": s[\"metadata\"][\"name\"], \"namespace\": \"cert-manager\"}, \"data\": s[\"data\"]}))' | kubectl --context $ctx apply --server-side --force-conflicts -f -"
    rec kubectl --context "$ctx" apply -f clusters/eg/eg-ca-issuer.yaml
  fi
  rec kubectl --context "$ctx" wait clusterissuer/eg-ca-issuer --for=condition=Ready --timeout=120s
done

# export the root once (gitignored — issue #60) and print the fingerprint
say "7b. export the lab root to .tmp/eg-root-ca.crt (not committed; issue #60)"
rec bash -c "kubectl --context kind-$ROOT_HOME -n cert-manager get secret eg-root-ca -o jsonpath='{.data.tls\\.crt}' | base64 -d > .tmp/eg-root-ca.crt"
rec openssl x509 -in .tmp/eg-root-ca.crt -noout -subject -issuer -fingerprint -sha256
echo "root PEM is .tmp/eg-root-ca.crt (gitignored). A committed copy drifts on every rebuild (issue #60)." | tee -a "$TRANSCRIPT"

# ---------------------------------------------------------------- (8) final table
say "8. final table — no load balancers, no Gateways, no apps (demos 51/52)"
{
  printf '%-8s %-48s %-10s %-12s %-8s %-12s %-14s %-14s %s\n' \
    CLUSTER NODES/IPs KUBEPROXY GW_API EG_CRDS GATEWAYCLASS ENVOY-GATEWAY CERT-MANAGER ROOT_SHA256
  for c in "$@"; do
    ctx="kind-$c"
    nodes=$(kubectl --context "$ctx" get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.addresses[?(@.type=="InternalIP")].address} {end}')
    mode=$(kubectl --context "$ctx" -n kube-system get cm kube-proxy -o yaml | awk '/^[[:space:]]*mode:/{print $2; exit}')
    gw=$(kubectl --context "$ctx" get crd -o name | grep -c '\.gateway\.networking\.k8s\.io$' || true)
    eg=$(kubectl --context "$ctx" get crd -o name | grep -c '\.gateway\.envoyproxy\.io$' || true)
    gc=$(kubectl --context "$ctx" get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')
    env=$(kubectl --context "$ctx" -n envoy-gateway-system get deploy envoy-gateway -o jsonpath='{.status.availableReplicas}/{.status.replicas}')
    cm=$(kubectl --context "$ctx" -n cert-manager get deploy cert-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
    fp=$(kubectl --context "$ctx" -n cert-manager get secret eg-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
    printf '%-8s %-48s %-10s %-12s %-8s %-12s %-14s %-14s %s\n' \
      "$c" "$nodes" "$mode" "${gw}@${GATEWAY_API_VERSION}" "$eg" "Accepted=$gc" "$env" "Available=$cm" "$fp"
  done
} | tee -a "$TRANSCRIPT"

echo "eg-up: done. Demos 51/52 install the load balancers and the Gateways." | tee -a "$TRANSCRIPT"
