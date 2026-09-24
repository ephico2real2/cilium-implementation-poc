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
#   scripts/fabric-servers-join.sh                 (the fabric must be up)
#   FABRIC_SERVERS_DEADLINE=120 demos/.../servers-join.sh
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
# Every difference between the two fabrics is a variable with a Desktop/CI
# default, so there is ONE implementation rather than a copy per fabric —
# which is the lesson this repository just spent fifteen thousand deleted
# lines learning. demos/46-bgp-fabric-colima's values are passed by
# scripts/demo46-colima-e2e.sh.
HERE="${FABRIC_DEMO_HERE:-demos/46-bgp-fabric-colima}"
CTX="${SERVERS_KUBE_CONTEXT:-kind-eg-poc1-colima}"
PROJECT="${FABRIC_PROJECT:-bgp-fabric-colima}"
DS="${FABRIC_KUBEVIP_DS:-demos/54-eg-poc1-kube-vip-colima/10b-kube-vip-ds-bgp-active-active.yaml}"
NODE_LAN="${FABRIC_NODE_LAN:-kind-eg-colima}"
LEAF1_LAN="${FABRIC_LEAF1_LAN:-172.20.254.11}"
LEAF2_LAN="${FABRIC_LEAF2_LAN:-172.20.254.12}"
# ${CTX_DOCKER-…} without the colon: UNSET means "this machine runs Colima",
# and CTX_DOCKER= set-but-empty means "no --context at all", which is what a
# CI runner with one daemon passes. With the colon, empty would have fallen
# back to the Colima default and every docker call on the runner would have
# named a context that does not exist there.
DOCKER_CTX="${CTX_DOCKER-colima-bgp-fabric}"
DOCKER_CTX_ARGS=()
[ -n "$DOCKER_CTX" ] && DOCKER_CTX_ARGS=(--context "$DOCKER_CTX")
DEADLINE="${FABRIC_SERVERS_DEADLINE:-120}"
TRANSCRIPT="${FABRIC_TRANSCRIPT:-$HERE/output/transcript.txt}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
COMPOSE=(docker "${DOCKER_CTX_ARGS[@]}" compose -p "$PROJECT" -f "$HERE/fabric/compose.yaml" -f "$HERE/fabric/compose.lan-eg.yaml")

# The leaves must already be on the node LAN, or the peers in the DaemonSet
# point at nothing and kube-vip retries for the whole deadline with no clue why.
for leaf in leaf1 leaf2; do
  cid=$("${COMPOSE[@]}" ps -q "$leaf" 2>/dev/null || true)
  [ -n "$cid" ] || { echo "servers-join: $leaf is not running — run $HERE/apply.sh first" >&2; exit 1; }
  ip=$(docker "${DOCKER_CTX_ARGS[@]}" inspect \
    -f "{{(index .NetworkSettings.Networks \"$NODE_LAN\").IPAddress}}" "$cid" 2>/dev/null || true)
  [ -n "$ip" ] || { echo "servers-join: $leaf is not on $NODE_LAN — the overlay is not applied" >&2; exit 1; }
  echo "servers-join: $leaf on $NODE_LAN at $ip"
done

# Whether the speaker must sign is a property of the KERNEL, measured, not a
# constant. FRR asks for TCP_MD5SIG per neighbour and per listen range: a
# kernel without CONFIG_TCP_MD5SIG answers ENOPROTOOPT, FRR logs "Unable to
# set TCP MD5 option ... Protocol not available" and the leaf then accepts an
# unsigned session — which is why demo 56's manifest carries no password, and
# it is right for the VM it was measured on. On a kernel that TAKES the option
# the leaf signs, and an unsigned speaker never gets past ACTIVE: the kernel
# discards its segments before FRR sees them, so nothing is logged on the leaf
# side at all (measured on a CI runner, 2026-09-24: kube-vip in BGP_FSM_ACTIVE
# with idle-hold-timer-expired, both leaves reporting one neighbour).
# NETWORK-TEAM-SHEET.md row 3 predicted exactly this: "on a real kernel the
# speaker signs".
FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-}"
if [ -z "$FABRIC_BGP_PASSWORD" ] && [ -f "$HERE/fabric/.env" ]; then
  # shellcheck disable=SC1091
  . "$HERE/fabric/.env"
fi
FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"

refused=0
for leaf in leaf1 leaf2; do
  "${COMPOSE[@]}" logs --no-log-prefix "$leaf" 2>/dev/null \
    | grep -qF 'Unable to set TCP MD5 option' && refused=1
done
if [ "$refused" -eq 1 ]; then
  peer_pw=""
  echo "servers-join: the leaves' kernel refused TCP_MD5SIG — the fabric runs unsigned, so the speaker sends no password"
else
  peer_pw="$FABRIC_BGP_PASSWORD"
  echo "servers-join: the leaves are signing — the speaker sends the fabric password"
fi

echo "== 1. kube-vip in BGP mode on $CTX (RBAC + the active-active DaemonSet)"
# demo 56's manifest, with the ONE field that depends on the kernel rendered
# for this one. Everything else about it is used as written; there is no
# second copy of this repository's kube-vip BGP DaemonSet and there should not
# be one.
rendered=$(mktemp) || exit 1
trap 'rm -f "$rendered"' EXIT
# Both spellings of the field: demo 56's is literally empty (its kernel
# refuses MD5), demo 54c's carries a __BGP_PASSWORD__ placeholder because
# Colima's kernel signs and that demo had already met this.
sed -E "s|[0-9.]+:65101:[^:,\"]*:false,[0-9.]+:65102:[^:,\"]*:false|${LEAF1_LAN}:65101:${peer_pw}:false,${LEAF2_LAN}:65102:${peer_pw}:false|" \
  "$DS" > "$rendered"
grep -q 'bgp_peers' "$rendered" || { echo "servers-join: bgp_peers not found in $DS" >&2; exit 1; }
rec bash -c "grep -A1 'name: bgp_peers' '$rendered' | tail -1 | sed 's/^ *//'"
# The cloud-provider is what writes status.loadBalancer.ingress; the
# DaemonSet announces what it finds there. Without it a Service stays
# <pending> for ever and nothing is ever announced.
rec kubectl --context "$CTX" apply -f clusters/eg/kube-vip-rbac.yaml \
  -f clusters/eg/kube-vip-cloud-provider.yaml -f "$rendered"
rec kubectl --context "$CTX" -n kube-system wait deploy/kube-vip-cloud-provider \
  --for=condition=Available --timeout=120s
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
