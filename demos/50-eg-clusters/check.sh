#!/usr/bin/env bash
# check.sh — demo 50 PASS/FAIL rows (demo 40's row() style). Exit = FAIL count.
#   demos/50-eg-clusters/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env

fails=0
row() { # ok|fail|warn  what  measured  rule
  local st
  case "$1" in
    ok)   st=PASS ;;
    fail) st=FAIL; fails=$((fails + 1)) ;;
    warn) st=WARN ;;
    *)    st=$1 ;;
  esac
  printf '  %-6s %-70s %-52s %s\n' "$st" "$2" "$3" "$4"
}

CLUSTERS="${CLUSTERS:-eg1 eg2}"
# shellcheck disable=SC2206
CLUSTER_ARR=($CLUSTERS)

printf '\n== demo 50 — the vanilla lab'\''s clusters (enhancement 007 phase 1)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

ipv4_in() { # ip cidr — 0 if ip is in cidr
  python3 -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)' "$1" "$2"
}

node_ipv4s() { # ctx — print "name ip" per IPv4 InternalIP
  kubectl --context "$1" get nodes -o json | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for n in doc["items"]:
    name = n["metadata"]["name"]
    for a in n.get("status", {}).get("addresses", []):
        if a.get("type") == "InternalIP" and ":" not in a["address"]:
            print("%s %s" % (name, a["address"]))
'
}

for c in "${CLUSTER_ARR[@]}"; do
  ctx="kind-$c"

  # R2 — nodes Ready
  ready=$(kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -c -v '^Ready$' || true)
  total=$(kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${total:-0}" -ge 2 ] && [ "${ready:-1}" -eq 0 ]; then
    row ok "$c nodes Ready" "Ready=$total" "R2 — every node Ready"
  else
    row fail "$c nodes Ready" "not-Ready=$ready total=${total:-0}" "R2 — every node Ready"
  fi

  # R1 — node IPs in the lower /17, none in the top /24
  ip_ok=1
  ip_list=""
  while read -r name ip; do
    [ -n "${ip:-}" ] || continue
    ip_list="${ip_list}${name}=${ip} "
    if ! ipv4_in "$ip" 172.19.0.0/17; then
      ip_ok=0
    fi
    if ipv4_in "$ip" 172.19.255.0/24; then
      ip_ok=0
    fi
  done < <(node_ipv4s "$ctx" 2>/dev/null || true)
  if [ "$ip_ok" -eq 1 ] && [ -n "$ip_list" ]; then
    row ok "$c node IPs in 172.19.0.0/17, none in 172.19.255.0/24" "$ip_list" "R1 / §3.1 — Docker --ip-range 172.19.0.0/17"
  else
    row fail "$c node IPs in 172.19.0.0/17, none in 172.19.255.0/24" "${ip_list:-none}" "R1 / §3.1 — Docker --ip-range 172.19.0.0/17"
  fi

  # R2 — kindnet
  kn=$(kubectl --context "$ctx" -n kube-system get ds kindnet -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)
  if [ -n "$kn" ] && [ "${kn#*/}" != "0" ] && [ "${kn%%/*}" = "${kn#*/}" ]; then
    row ok "$c kindnet DaemonSet" "ready=$kn" "R2 — kindnet present"
  else
    row fail "$c kindnet DaemonSet" "ready=${kn:-absent}" "R2 — kindnet present"
  fi

  # R2 — kube-proxy iptables
  kp=$(kubectl --context "$ctx" -n kube-system get ds kube-proxy -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)
  mode=$(kubectl --context "$ctx" -n kube-system get cm kube-proxy -o yaml 2>/dev/null | awk '/^[[:space:]]*mode:/{print $2; exit}' || true)
  if [ -n "$kp" ] && [ "$mode" = iptables ]; then
    row ok "$c kube-proxy mode iptables" "ds=$kp mode=$mode" "R2 — kube-proxy present, mode iptables"
  else
    row fail "$c kube-proxy mode iptables" "ds=${kp:-absent} mode=${mode:-?}" "R2 — kube-proxy present, mode iptables"
  fi

  # R2 — no Cilium anywhere
  cilium_ds=$(kubectl --context "$ctx" get ds -A 2>/dev/null | grep -c cilium || true)
  if [ "${cilium_ds:-0}" -eq 0 ]; then
    row ok "$c no Cilium DaemonSet" "grep -c cilium=$cilium_ds" "R2 — kubectl get ds -A | grep -c cilium = 0"
  else
    row fail "$c no Cilium DaemonSet" "grep -c cilium=$cilium_ds" "R2 — kubectl get ds -A | grep -c cilium = 0"
  fi

  # R3 / D5 / D10 — 10 Gateway API CRDs at the pin, every one channel: standard
  gw_n=$(kubectl --context "$ctx" get crd -o name 2>/dev/null | grep -c '\.gateway\.networking\.k8s\.io$' || true)
  gw_bad=0
  gw_ver=""
  while read -r crd; do
    [ -n "$crd" ] || continue
    ch=$(kubectl --context "$ctx" get "$crd" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}' 2>/dev/null || true)
    ver=$(kubectl --context "$ctx" get "$crd" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || true)
    gw_ver=$ver
    if [ "$ch" != standard ] || [ "$ver" != "$GATEWAY_API_VERSION" ]; then
      gw_bad=$((gw_bad + 1))
    fi
  done < <(kubectl --context "$ctx" get crd -o name 2>/dev/null | grep '\.gateway\.networking\.k8s\.io$' || true)
  if [ "$gw_n" -eq 10 ] && [ "$gw_bad" -eq 0 ]; then
    row ok "$c 10 Gateway API CRDs channel=standard $GATEWAY_API_VERSION" "n=$gw_n bad=$gw_bad ver=$gw_ver" "D10 / R3 — every gateway.networking.k8s.io CRD channel: standard, bundle-version $GATEWAY_API_VERSION"
  else
    row fail "$c 10 Gateway API CRDs channel=standard $GATEWAY_API_VERSION" "n=$gw_n bad=$gw_bad ver=${gw_ver:-?}" "D10 / R3 — every gateway.networking.k8s.io CRD channel: standard, bundle-version $GATEWAY_API_VERSION"
  fi

  # R3 — 8 Envoy Gateway CRDs
  eg_n=$(kubectl --context "$ctx" get crd -o name 2>/dev/null | grep -c '\.gateway\.envoyproxy\.io$' || true)
  if [ "$eg_n" -eq 8 ]; then
    row ok "$c 8 gateway.envoyproxy.io CRDs" "n=$eg_n" "R3 — Envoy Gateway's own CRDs from gateway-crds-helm"
  else
    row fail "$c 8 gateway.envoyproxy.io CRDs" "n=$eg_n" "R3 — Envoy Gateway's own CRDs from gateway-crds-helm"
  fi

  # R3 — helm list shows eg (and eg-crds if a release)
  rels=$(helm list -n envoy-gateway-system --kube-context "$ctx" -q 2>/dev/null | tr '\n' ' ' || true)
  case " $rels " in
    *" eg "*) helm_eg=1 ;;
    *) helm_eg=0 ;;
  esac
  case " $rels " in
    *" eg-crds "*) helm_crds=1 ;;
    *) helm_crds=0 ;;
  esac
  if [ "$helm_eg" -eq 1 ]; then
    if [ "$helm_crds" -eq 1 ]; then
      row ok "$c helm list shows eg and eg-crds" "$rels" "R3 — helm list -n envoy-gateway-system shows eg (and eg-crds if a release)"
    else
      row ok "$c helm list shows eg (eg-crds not a release)" "$rels" "R3 — helm list -n envoy-gateway-system shows eg (and eg-crds if a release)"
    fi
  else
    row fail "$c helm list shows eg" "${rels:-empty}" "R3 — helm list -n envoy-gateway-system shows eg (and eg-crds if a release)"
  fi

  # R3 — GatewayClass eg Accepted
  gc=$(kubectl --context "$ctx" get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  if [ "$gc" = True ]; then
    row ok "$c GatewayClass eg Accepted" "Accepted=$gc" "R3 — GatewayClass eg Accepted (chart does not create it)"
  else
    row fail "$c GatewayClass eg Accepted" "Accepted=${gc:-?}" "R3 — GatewayClass eg Accepted (chart does not create it)"
  fi

  # R3 — envoy-gateway Available
  env_av=$(kubectl --context "$ctx" -n envoy-gateway-system get deploy envoy-gateway -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  if [ "$env_av" = True ]; then
    row ok "$c envoy-gateway Deployment Available" "Available=$env_av" "R3 — envoy-gateway Deployment Available"
  else
    row fail "$c envoy-gateway Deployment Available" "Available=${env_av:-?}" "R3 — envoy-gateway Deployment Available"
  fi

  # cert-manager Available
  cm_av=$(kubectl --context "$ctx" -n cert-manager get deploy cert-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  if [ "$cm_av" = True ]; then
    row ok "$c cert-manager Deployment Available" "Available=$cm_av" "lab-up.sh form — cert-manager $CERT_MANAGER_VERSION Available"
  else
    row fail "$c cert-manager Deployment Available" "Available=${cm_av:-?}" "lab-up.sh form — cert-manager $CERT_MANAGER_VERSION Available"
  fi

  # D8 — ClusterIssuer Ready
  iss=$(kubectl --context "$ctx" get clusterissuer eg-ca-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "$iss" = True ]; then
    row ok "$c ClusterIssuer eg-ca-issuer Ready" "Ready=$iss" "D8 — ClusterIssuer eg-ca-issuer Ready"
  else
    row fail "$c ClusterIssuer eg-ca-issuer Ready" "Ready=${iss:-?}" "D8 — ClusterIssuer eg-ca-issuer Ready"
  fi
done

# D8 — the same root fingerprint in both clusters
fp_of() {
  kubectl --context "$1" -n cert-manager get secret eg-root-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}
fp1=$(fp_of kind-eg1)
fp2=$(fp_of kind-eg2)
if [ -n "$fp1" ] && [ "$fp1" = "$fp2" ]; then
  row ok "root fingerprint identical in both clusters" "$fp1" "D8 — the SAME root in both clusters (copied Secret)"
else
  row fail "root fingerprint identical in both clusters" "eg1=${fp1:-?} eg2=${fp2:-?}" "D8 — the SAME root in both clusters (copied Secret)"
fi

# R1 — kind-eg ip-range is the lower /17 (IPv4 only: the IPv6 block has no
# --ip-range and docker inspect prints "invalid Prefix" for it)
ipr=$(docker network inspect kind-eg --format '{{range .IPAM.Config}}{{.Subnet}} {{.IPRange}}{{"\n"}}{{end}}' 2>/dev/null | awk '/^172\.19\.0\.0\/16/{print $2; exit}')
if [ "$ipr" = "172.19.0.0/17" ]; then
  row ok "kind-eg ip-range is 172.19.0.0/17" "$ipr" "R1 / §3.1 — docker network inspect kind-eg ip-range"
else
  row fail "kind-eg ip-range is 172.19.0.0/17" "${ipr:-absent}" "R1 / §3.1 — docker network inspect kind-eg ip-range"
fi

# Mac route 172.19/16 — WARN, not FAIL (phase 0 item 1; no script runs sudo)
route_line=""
if [ "$(uname -s)" = Darwin ]; then
  route_line=$(netstat -rn -f inet 2>/dev/null | awk '/^172\.19[[:space:]]/{print}' || true)
else
  route_line=$(ip route show 172.19.0.0/16 2>/dev/null || true)
fi
if [ -n "$route_line" ]; then
  row ok "host route 172.19/16 present" "$route_line" "phase 0 item 1 — Mac route 172.19/16 (WARN if absent)"
else
  row warn "host route 172.19/16 present" "absent" "phase 0 item 1 — sudo route -n add -net 172.19.0.0/16 192.168.64.2"
fi

echo
echo "demo 50 check: $fails FAIL"
exit "$fails"
