#!/usr/bin/env bash
# servers-join.sh — make the cluster's nodes dial the leaves, and prove they did.
#
# Demo 46 builds a fabric whose leaves LISTEN for servers instead of naming
# them. With nothing dialling in, the page reports `server sessions 0/0` — the
# truth, and the least interesting truth it can tell. This brings kube-vip up
# in BGP mode on the cluster so both nodes peer with both leaves, and then
# waits for the leaves' own `show bgp summary json` to say so.
#
# The DaemonSet is demo 56's (it is this repository's kube-vip BGP manifest;
# there is no second copy). Nothing else of demo 56 is applied — no Gateways,
# no apps, no VIPs are announced. The claim here is only that a server can
# arrive through a listen range, which is demo 46's claim about its own leaves.
#
#   demos/46-bgp-fabric/servers-join.sh            (the fabric must be up)
#   FABRIC_SERVERS_DEADLINE=120 demos/.../servers-join.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
HERE=demos/46-bgp-fabric
CTX="${SERVERS_KUBE_CONTEXT:-kind-eg-poc1}"
PROJECT="${FABRIC_PROJECT:-bgp-fabric}"
DS=demos/56-kube-vip-bgp/10b-kube-vip-ds-bgp-active-active.yaml
DEADLINE="${FABRIC_SERVERS_DEADLINE:-120}"
TRANSCRIPT="${FABRIC_TRANSCRIPT:-$HERE/output/transcript.txt}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
COMPOSE=(docker compose -p "$PROJECT" -f "$HERE/fabric/compose.yaml" -f "$HERE/fabric/compose.lan-eg.yaml")

# The leaves must already be on the node LAN, or the peers in the DaemonSet
# point at nothing and kube-vip retries for the whole deadline with no clue why.
for leaf in leaf1 leaf2; do
  cid=$("${COMPOSE[@]}" ps -q "$leaf" 2>/dev/null || true)
  [ -n "$cid" ] || { echo "servers-join: $leaf is not running — run $HERE/apply.sh first" >&2; exit 1; }
  ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "$cid" 2>/dev/null || true)
  [ -n "$ip" ] || { echo "servers-join: $leaf is not on kind-eg — the overlay is not applied" >&2; exit 1; }
  echo "servers-join: $leaf on kind-eg at $ip"
done

echo "== 1. kube-vip in BGP mode on $CTX (RBAC + the active-active DaemonSet)"
rec kubectl --context "$CTX" apply -f clusters/eg/kube-vip-rbac.yaml -f "$DS"
rec kubectl --context "$CTX" -n kube-system rollout status ds/kube-vip-ds --timeout=120s

node_ips=$(kubectl --context "$CTX" get nodes \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
  | grep -v ':' | sort)
[ -n "$node_ips" ] || { echo "servers-join: no node InternalIPs" >&2; exit 1; }
want=0
for _ in $node_ips; do want=$((want + 2)); done   # every node, both leaves

echo "== 2. wait for $want SERVERS sessions (deadline ${DEADLINE}s)"
start=$(date +%s)
est=0
while :; do
  est=0
  for leaf in leaf1 leaf2; do
    raw=$("${COMPOSE[@]}" exec -T "$leaf" vtysh -c 'show bgp summary json' 2>/dev/null) || raw=""
    [ -n "$raw" ] || continue
    for ip in $node_ips; do
      printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py --require "$ip" >/dev/null 2>&1 \
        && est=$((est + 1))
    done
  done
  [ "$est" -ge "$want" ] && break
  now=$(date +%s)
  [ $((now - start)) -ge "$DEADLINE" ] && break
  sleep 3
done
elapsed=$(( $(date +%s) - start ))
if [ "$est" -lt "$want" ]; then
  echo "servers-join: $est/$want SERVERS sessions after ${elapsed}s" >&2
  rec echo "SERVERS sessions $est/$want after ${elapsed} s"
  rec "${COMPOSE[@]}" exec -T leaf1 vtysh -c 'show bgp summary'
  rec "${COMPOSE[@]}" exec -T leaf2 vtysh -c 'show bgp summary'
  rec kubectl --context "$CTX" -n kube-system logs ds/kube-vip-ds --tail=40
  exit 1
fi
rec echo "SERVERS sessions $est/$want Established after ${elapsed} s ($(echo "$node_ips" | tr '\n' ' '))"

echo "== 3. the leaves' own view"
rec "${COMPOSE[@]}" exec -T leaf1 vtysh -c 'show bgp summary'
rec "${COMPOSE[@]}" exec -T leaf2 vtysh -c 'show bgp summary'

echo "== 4. what the page now reports"
DASH="http://127.0.0.1:${FABRIC_DASHBOARD_PORT:-8088}"
rec bash -c "curl -fsS --max-time 5 '${DASH}/api/state' | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(\"routers=%s/%s fabric=%s/%s server=%s/%s external=%s\" % (
    d.get(\"reachable\"), d.get(\"routerCount\"),
    d.get(\"established\"), d.get(\"sessionCount\"),
    d.get(\"serverEstablished\"), d.get(\"serverSessions\"), d.get(\"external\")))'"
echo "servers-join: $est/$want Established; the page is at ${DASH}/"
