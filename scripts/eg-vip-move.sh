#!/usr/bin/env bash
# eg-vip-move.sh — move the Envoy Gateway shared VIP (.16) from one cluster to the other.
#
# Delete the VIP Gateway + its routes + its EnvoyProxy from the OTHER cluster first,
# then create them in the target. Two announcers for one address is the failure the
# whole design avoids; a short gap is the price (demo 40's delete-other-first rule).
# kube-vip announces whatever Service carries kube-vip.io/loadbalancerIPs, so the
# Gateway itself is the announcement — unlike Cilium, where shop-vip-announce was a
# separate L2 policy and the Gateway could exist in both clusters.
#
#   scripts/eg-vip-move.sh kube-vip eg1|eg2
#   scripts/eg-vip-move.sh --status
#
# The first argument is the load balancer (demo 52 will add `metallb`). Only
# kube-vip is implemented here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/demos/51-eg-kube-vip"
VIP="172.19.255.16"

yaml_select() { # file name [name...]
  python3 - "$@" <<'PY'
import sys, re
path, *names = sys.argv[1:]
want = set(names)
text = open(path).read()
for part in re.split(r"(?m)^---\s*\n", text):
    m = re.search(r"(?m)^  name:\s+(\S+)", part)
    if not m:
        m = re.search(r"metadata:\s*\{name:\s*([^,\s}]+)", part)
    if m and m.group(1) in want:
        sys.stdout.write("---\n")
        sys.stdout.write(part if part.endswith("\n") else part + "\n")
PY
}

ctx_of() {
  case "$1" in
    eg1|kind-eg1) echo kind-eg1 ;;
    eg2|kind-eg2) echo kind-eg2 ;;
    *) echo "usage: $0 kube-vip eg1|eg2 | --status" >&2; exit 2 ;;
  esac
}

gw_file() {
  case "$1" in
    kind-eg1) echo "$HERE/30-gateways-eg1.yaml" ;;
    kind-eg2) echo "$HERE/30-gateways-eg2.yaml" ;;
  esac
}

routes_file() {
  case "$1" in
    kind-eg1) echo "$HERE/50-routes-eg1.yaml" ;;
    kind-eg2) echo "$HERE/50-routes-eg2.yaml" ;;
  esac
}

reachable() {
  kubectl --context "$1" get --raw /readyz >/dev/null 2>&1
}

has_vip() {
  kubectl --context "$1" -n shop get gateway eg-vip-gw >/dev/null 2>&1
}

arping_vip() {
  docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -c 3 -I eth0 "$VIP" 2>&1 || true
}

mac_to_node() { # mac → node name from docker network inspect kind-eg
  local mac=$1
  python3 - "$mac" <<'PY'
import json, subprocess, sys
want = sys.argv[1].lower()
net = json.loads(subprocess.check_output(["docker", "network", "inspect", "kind-eg"]))[0]
for c in net.get("Containers", {}).values():
    mac = (c.get("MacAddress") or "").lower()
    if mac == want:
        print(c.get("Name", "?"), c.get("IPv4Address", ""))
        break
else:
    print("unknown")
PY
}

who_has_vip() {
  local holder="" ctx
  for ctx in kind-eg1 kind-eg2; do
    if ! reachable "$ctx"; then
      continue
    fi
    if has_vip "$ctx"; then
      if [ -n "$holder" ]; then
        echo "BOTH ($holder and ${ctx#kind-})"
        return
      fi
      holder=${ctx#kind-}
    fi
  done
  echo "${holder:-none}"
}

status() {
  echo "== VIP $VIP present in: $(who_has_vip)"
  local ctx
  for ctx in kind-eg1 kind-eg2; do
    echo "-- ${ctx#kind-}"
    if ! reachable "$ctx"; then
      echo "  API unreachable — VIP state UNKNOWN"
      continue
    fi
    if has_vip "$ctx"; then
      addr=$(kubectl --context "$ctx" -n shop get gateway eg-vip-gw \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '?')
      prog=$(kubectl --context "$ctx" -n shop get gateway eg-vip-gw \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo '?')
      echo "  eg-vip-gw: present address=$addr Programmed=$prog"
    else
      echo "  eg-vip-gw: absent"
    fi
  done
  echo "== arping $VIP"
  local out mac
  out=$(arping_vip)
  echo "$out"
  mac=$(printf '%s\n' "$out" | awk '/Unicast reply/{gsub(/[\[\]]/,"",$5); print $5; exit}')
  if [ -n "$mac" ]; then
    echo "== responder MAC $mac → $(mac_to_node "$mac")"
  else
    echo "== responder MAC: none (0 ARP replies)"
  fi
}

delete_vip() { # ctx
  local ctx=$1
  echo "== delete VIP objects from ${ctx#kind-} first"
  kubectl --context "$ctx" -n shop delete httproute shop-api-vip shop-redirect-vip --ignore-not-found
  kubectl --context "$ctx" -n shop delete grpcroute grpc-vip --ignore-not-found
  kubectl --context "$ctx" -n shop delete gateway eg-vip-gw --ignore-not-found
  kubectl --context "$ctx" -n shop delete envoyproxy eg-vip-gw-proxy --ignore-not-found
  # The announcement is the Envoy Service, not the Gateway: kube-vip stops ARP when
  # the Service is deleted (watch.Deleted), and that Service is owned by the
  # GatewayClass and carries service.kubernetes.io/load-balancer-cleanup, so it
  # outlives `kubectl delete gateway` until Envoy Gateway and the cloud-provider
  # have both acted (measured 2026-09-18: 66 ms after the Gateway; unbounded if
  # the cloud-provider is down). Wait for it before the target may announce.
  # With nothing matching (same-target rerun) kubectl wait returns 0 at once.
  kubectl --context "$ctx" -n envoy-gateway-system wait svc \
    -l gateway.envoyproxy.io/owning-gateway-name=eg-vip-gw --for=delete --timeout=60s
}

apply_vip() { # ctx
  local ctx=$1
  echo "== create VIP Gateway + EnvoyProxy + routes on ${ctx#kind-}"
  yaml_select "$(gw_file "$ctx")" eg-vip-gw-proxy eg-vip-gw \
    | kubectl --context "$ctx" apply -f -
  yaml_select "$(routes_file "$ctx")" shop-api-vip shop-redirect-vip grpc-vip \
    | kubectl --context "$ctx" apply -f -
  kubectl --context "$ctx" -n shop wait --for=condition=Programmed gateway/eg-vip-gw --timeout=180s
  local i
  for i in $(seq 1 36); do
    if kubectl --context "$ctx" -n envoy-gateway-system get deploy \
         -l "gateway.envoyproxy.io/owning-gateway-name=eg-vip-gw" \
         -o name 2>/dev/null | grep -q .; then
      kubectl --context "$ctx" -n envoy-gateway-system wait deploy \
        -l "gateway.envoyproxy.io/owning-gateway-name=eg-vip-gw" \
        --for=condition=Available --timeout=180s
      return 0
    fi
    sleep 5
  done
  echo "eg-vip-move: no Envoy Deployment for eg-vip-gw on ${ctx#kind-} after 180s" >&2
  return 1
}

if [ "${1:-}" = "--status" ] || [ "${1:-}" = "-s" ]; then
  status
  exit 0
fi

if [ "${1:-}" != "kube-vip" ]; then
  echo "usage: $0 kube-vip eg1|eg2 | --status" >&2
  echo "(metallb is demo 52)" >&2
  exit 2
fi

TARGET=$(ctx_of "${2:-}")
OTHER=kind-eg2
if [ "$TARGET" = "kind-eg2" ]; then
  OTHER=kind-eg1
fi

echo "== takeover: ${TARGET#kind-} will announce $VIP (delete ${OTHER#kind-} first)"
if reachable "$OTHER"; then
  delete_vip "$OTHER"
else
  echo "eg-vip-move: ${OTHER#kind-} API unreachable — refusing to apply to ${TARGET#kind-}" >&2
  echo "eg-vip-move: two announcers is the failure this script exists to prevent" >&2
  exit 1
fi
apply_vip "$TARGET"
echo "== after"
status
