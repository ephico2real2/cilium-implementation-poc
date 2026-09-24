#!/usr/bin/env bash
# traffic.sh — announce a service address into the fabric and carry a packet
# to it from the other side.
#
# Everything demo 46 checks otherwise is the fabric talking about itself: the
# routers originate their own loopbacks and their own WAN, so no address in
# the lab belongs to anything outside it. This announces 10.98.0.46/32 from a
# cluster in AS 65021 and then uses it from client0, on the WAN, four
# autonomous systems away.
#
# The plan, the address and what each hop's policy permits:
#   docs/DEMO46_DATA_PATH.md
#
#   demos/46-bgp-fabric/traffic.sh     (the fabric, the cluster and
#                                       servers-join.sh must have run)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# Desktop/CI defaults; scripts/demo46-colima-e2e.sh passes the Colima ones.
# The VIP differs between the two fabrics because their prefix-lists do:
# 10.98.0.0/26 here, 10.198.0.0/26 there. An address is only reachable if a
# prefix-list already names its block — see docs/DEMO46_DATA_PATH.md.
HERE="${DEMO46_HERE:-demos/46-bgp-fabric}"
CTX="${SERVERS_KUBE_CONTEXT:-kind-eg-poc1}"
PROJECT="${FABRIC_PROJECT:-bgp-fabric}"
VIP="${DEMO46_VIP:-10.98.0.46}"
PROBE="${DEMO46_PROBE_MANIFEST:-$HERE/probe/10-probe.yaml}"
DOCKER_CTX_ARGS=()
[ -n "${CTX_DOCKER:-}" ] && DOCKER_CTX_ARGS=(--context "$CTX_DOCKER")
DEADLINE="${DEMO46_TRAFFIC_DEADLINE:-120}"
TRANSCRIPT="${FABRIC_TRANSCRIPT:-$HERE/output/transcript.txt}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
COMPOSE=(docker "${DOCKER_CTX_ARGS[@]}" compose -p "$PROJECT" -f "$HERE/fabric/compose.yaml" -f "$HERE/fabric/compose.lan-eg.yaml")

fails=0
row() { # ok|fail  what  measured
  local st=PASS
  [ "$1" = ok ] || { st=FAIL; fails=$((fails + 1)); }
  printf '  %-6s %-46s %s\n' "$st" "$2" "$3"
}

echo "== 1. the probe: two pods and a LoadBalancer Service at $VIP"
# The address in the manifest is the default one; a different fabric passes
# its own with DEMO46_VIP, and the annotation is rewritten to match.
rendered=$(mktemp) || exit 1
trap 'rm -f "$rendered"' EXIT
sed "s|kube-vip.io/loadbalancerIPs: \"10.98.0.46\"|kube-vip.io/loadbalancerIPs: \"$VIP\"|" "$PROBE" > "$rendered"
rec kubectl --context "$CTX" apply -f "$rendered"
rec kubectl --context "$CTX" -n demo46 rollout status deploy/demo46-probe --timeout=120s

# kube-vip's cloud-provider is what writes status.loadBalancer.ingress; the
# DaemonSet announces what it finds there. Waiting on the Service rather than
# on a fixed sleep, because "the address was assigned" is the precondition for
# everything below and its absence has its own message.
echo "== 2. wait for the address to be assigned (deadline ${DEADLINE}s)"
start=$(date +%s)
assigned=""
while :; do
  assigned=$(kubectl --context "$CTX" -n demo46 get svc demo46-probe \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ "$assigned" = "$VIP" ] && break
  [ $(( $(date +%s) - start )) -ge "$DEADLINE" ] && break
  sleep 2
done
if [ "$assigned" != "$VIP" ]; then
  echo "traffic: the Service has ingress '${assigned:-<none>}', want $VIP" >&2
  rec kubectl --context "$CTX" -n demo46 get svc demo46-probe -o wide
  rec kubectl --context "$CTX" -n kube-system logs deploy/kube-vip-cloud-provider --tail=30
  exit 1
fi
rec echo "Service demo46-probe ingress $assigned after $(( $(date +%s) - start )) s"

echo
echo "== 3. the seven claims, in order"
printf '  %-6s %-46s %s\n' STATUS WHAT MEASURED

# (1) the leaves accepted it, with the as-path that let it in
for leaf in leaf1 leaf2; do
  raw=$("${COMPOSE[@]}" exec -T "$leaf" vtysh -c "show bgp ipv4 unicast $VIP/32 json" 2>/dev/null) || raw=""
  paths=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print(",".join(p.get("aspath", {}).get("string", "") for p in d.get("paths", [])))' 2>/dev/null)
  case "$paths" in
    *65021*) row ok  "$leaf has $VIP/32" "as-path $paths" ;;
    *)       row fail "$leaf has $VIP/32" "paths=[${paths:-none}]" ;;
  esac
done

# (2) policy did the accepting — SERVERS-IN sequence 10 was invoked. A prefix
# in the table says nothing about WHICH rule let it in; this does.
rm_raw=$("${COMPOSE[@]}" exec -T leaf1 vtysh -c 'show route-map SERVERS-IN json' 2>/dev/null) || rm_raw=""
inv=$(printf '%s' "$rm_raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("-1"); raise SystemExit
rules = ((((d.get("bgpd") or d.get("bgp")) or {}).get("SERVERS-IN") or {}).get("rules")) or []
for r in rules:
    if r.get("sequenceNumber") == 10:
        print(r.get("invoked", 0)); break
else:
    print("-1")' 2>/dev/null)
if [ "${inv:--1}" -gt 0 ] 2>/dev/null; then
  row ok "SERVERS-IN seq 10 did the accepting" "invoked=$inv"
else
  row fail "SERVERS-IN seq 10 did the accepting" "invoked=${inv:-?}"
fi

# (3) it crossed the fabric — the spine holds it with BOTH leaves as nexthops,
# and the edge holds it too
sp=$("${COMPOSE[@]}" exec -T spine vtysh -c "show bgp ipv4 unicast $VIP/32 json" 2>/dev/null) || sp=""
nh=$(printf '%s' "$sp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
out = []
for p in d.get("paths", []):
    for n in p.get("nexthops", []):
        if n.get("ip"):
            out.append(n["ip"])
print(",".join(sorted(set(out))))' 2>/dev/null)
n_nh=$(printf '%s' "$nh" | tr ',' '\n' | grep -c '\.' || true)
if [ "${n_nh:-0}" -ge 2 ]; then
  row ok "spine has two nexthops for $VIP/32" "$nh"
else
  row fail "spine has two nexthops for $VIP/32" "nexthops=[${nh:-none}] (want 2)"
fi
eg=$("${COMPOSE[@]}" exec -T edge vtysh -c "show bgp ipv4 unicast $VIP/32 json" 2>/dev/null) || eg=""
if printf '%s' "$eg" | grep -q '"aspath"'; then
  row ok "edge has $VIP/32" "learned from the spine"
else
  row fail "edge has $VIP/32" "absent from the edge's table"
fi

# (4) the KERNEL installed it. A BGP table entry is a decision; a FIB entry is
# what forwards a packet, and only one of the two moves traffic.
kr=$("${COMPOSE[@]}" exec -T spine ip route show "$VIP" 2>/dev/null) || kr=""
if printf '%s' "$kr" | grep -q 'nexthop'; then
  row ok "spine FIB has an ECMP route" "$(printf '%s' "$kr" | tr '\n' ' ' | cut -c1-60)"
elif [ -n "$kr" ]; then
  row ok "spine FIB has a route" "$(printf '%s' "$kr" | head -1 | cut -c1-60)"
else
  row fail "spine FIB has a route" "ip route show $VIP is empty"
fi

# (5) a packet arrives, and the body says which pod answered
body=$("${COMPOSE[@]}" exec -T client0 curl -fsS --max-time 5 "http://$VIP/" 2>/dev/null) || body=""
case "$body" in
  demo46-probe*) row ok "client0 reaches $VIP" "$body" ;;
  *)             row fail "client0 reaches $VIP" "body=[${body:-empty}]" ;;
esac

# (6) repeatedly — one answer could be luck, and the count is reported
ok_n=0
for _ in $(seq 1 20); do
  "${COMPOSE[@]}" exec -T client0 curl -fsS --max-time 3 -o /dev/null "http://$VIP/" 2>/dev/null \
    && ok_n=$((ok_n + 1))
done
if [ "$ok_n" -eq 20 ]; then
  row ok "20 requests from client0" "20/20 answered"
else
  row fail "20 requests from client0" "$ok_n/20 answered"
fi

# (7) the page knows. The dashboard reads the routers, so the VIP being in its
# state is the fabric's own view arriving at the operator's.
st=$(curl -fsS --max-time 5 "http://127.0.0.1:${FABRIC_DASHBOARD_PORT:-8088}/api/state" 2>/dev/null) || st=""
if printf '%s' "$st" | grep -qF "$VIP"; then
  row ok "the dashboard shows $VIP" "present in /api/state"
else
  row fail "the dashboard shows $VIP" "absent from /api/state"
fi

echo
echo "== 4. the path, recorded"
rec "${COMPOSE[@]}" exec -T client0 traceroute -n -m 6 "$VIP"
rec "${COMPOSE[@]}" exec -T spine ip route show "$VIP"
rec "${COMPOSE[@]}" exec -T leaf1 vtysh -c "show bgp ipv4 unicast $VIP/32"
# Six replies, each recorded on its own line. Two pods behind the address and
# ECMP across two leaves, so the node names in these six are the only place
# the transcript says which end actually answered.
for _ in 1 2 3 4 5 6; do
  rec "${COMPOSE[@]}" exec -T client0 curl -fsS --max-time 3 "http://$VIP/"
done

echo
echo "demo 46 traffic: $fails FAIL"
exit "$fails"
