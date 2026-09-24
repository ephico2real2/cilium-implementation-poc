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
#   scripts/fabric-traffic.sh          (the fabric, the cluster and
#                                       fabric-servers-join.sh must have run)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# Desktop/CI defaults; scripts/demo46-colima-e2e.sh passes the Colima ones.
# The VIP differs between the two fabrics because their prefix-lists do:
# 10.98.0.0/26 here, 10.198.0.0/26 there. An address is only reachable if a
# prefix-list already names its block — see docs/DEMO46_DATA_PATH.md.
HERE="${FABRIC_DEMO_HERE:-demos/46-bgp-fabric-colima}"
CTX="${SERVERS_KUBE_CONTEXT:-kind-eg-poc1-colima}"
PROJECT="${FABRIC_PROJECT:-bgp-fabric-colima}"
VIP="${FABRIC_VIP:-10.198.0.46}"
PROBE="${FABRIC_PROBE_MANIFEST:-clusters/bgp-fabric-probe.yaml}"
LEAF1_LAN="${FABRIC_LEAF1_LAN:-172.20.254.11}"
# ${CTX_DOCKER-…} without the colon: UNSET means "this machine runs Colima",
# and CTX_DOCKER= set-but-empty means "no --context at all", which is what a
# CI runner with one daemon passes. With the colon, empty would have fallen
# back to the Colima default and every docker call on the runner would have
# named a context that does not exist there.
DOCKER_CTX="${CTX_DOCKER-colima-bgp-fabric}"
DOCKER_CTX_ARGS=()
[ -n "$DOCKER_CTX" ] && DOCKER_CTX_ARGS=(--context "$DOCKER_CTX")
DEADLINE="${FABRIC_TRAFFIC_DEADLINE:-120}"
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
# its own with FABRIC_VIP, and the annotation is rewritten to match.
rendered=$(mktemp) || exit 1
trap 'rm -f "$rendered"' EXIT
sed -e "s|kube-vip.io/loadbalancerIPs: \"10.198.0.46\"|kube-vip.io/loadbalancerIPs: \"$VIP\"|" \
    -e "s|cidr-demo46: 10.198.0.46/32|cidr-demo46: $VIP/32|" "$PROBE" > "$rendered"
rec kubectl --context "$CTX" apply -f "$rendered"
if ! kubectl --context "$CTX" -n demo46 rollout status deploy/demo46-probe --timeout=120s; then
  # A Service address is pointless if nothing can answer on it. The previous
  # run waited the full deadline for an address while both pods were in
  # CrashLoopBackOff, and the reason was three screens further down.
  echo "traffic: the probe pods never became ready" >&2
  rec kubectl --context "$CTX" -n demo46 get pods -o wide
  rec kubectl --context "$CTX" -n demo46 describe deploy/demo46-probe
  rec kubectl --context "$CTX" -n demo46 logs -l app=demo46-probe --tail=40 --all-containers --prefix
  exit 1
fi
rec kubectl --context "$CTX" -n demo46 get pods -o wide

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
  # Everything that decides whether an address is assigned and announced. The
  # first run of this printed the Service and the cloud-provider only, and the
  # cloud-provider said "EnsuredLoadBalancer" while the Service stayed
  # <pending> — so the answer was in neither.
  rec kubectl --context "$CTX" -n demo46 get svc demo46-probe -o yaml
  rec kubectl --context "$CTX" -n demo46 get events --sort-by=.lastTimestamp
  rec kubectl --context "$CTX" -n kube-system get cm kubevip -o yaml
  rec kubectl --context "$CTX" -n kube-system logs deploy/kube-vip-cloud-provider --tail=40
  rec kubectl --context "$CTX" -n kube-system logs ds/kube-vip-ds --tail=60
  exit 1
fi
rec echo "Service demo46-probe ingress $assigned after $(( $(date +%s) - start )) s"

# The node's way back. Its default gateway is the Docker bridge, not a leaf,
# and Docker does not forward between two bridges — so a reply to client0
# leaves by the default route and is dropped. Measured both ways: in CI the
# traceroute from client0 reached leaf1 at hop 3 and stopped; on a laptop
# where this route IS installed the same request answers 200.
#
# This is not a BGP change and the leaves still advertise nothing to their
# server peers — that contract is deliberate and stays. It is the node's own
# network configuration, which in a real deployment would already point at the
# ToR as its default gateway. demos/54-eg-poc1-kube-vip-colima/apply.sh does
# exactly this at its step 7b, for exactly this reason.
echo "== 2b. the node's return route to the company fabric, via a leaf"
NODES=$(kubectl --context "$CTX" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for n in $NODES; do
  rec docker "${DOCKER_CTX_ARGS[@]}" exec "$n" ip route replace 10.200.0.0/16 via "$LEAF1_LAN"
done
for n in $NODES; do
  rec docker "${DOCKER_CTX_ARGS[@]}" exec "$n" ip route show 10.200.0.0/16
done

echo
echo "== 3. the eight claims, in order"
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

# (4b) the node can answer. Without this route the request arrives and the
# reply is dropped by Docker's inter-bridge isolation, which looks exactly
# like "the fabric does not work" from client0 and is not.
back=""
for n in $NODES; do
  back=$(docker "${DOCKER_CTX_ARGS[@]}" exec "$n" ip route show 10.200.0.0/16 2>/dev/null | head -1)
  [ -n "$back" ] || break
done
if [ -n "$back" ]; then
  row ok "the nodes can route back to the fabric" "$back"
else
  row fail "the nodes can route back to the fabric" "10.200.0.0/16 absent on a node"
fi

# (5) a packet arrives, and the body says which pod answered
body=$("${COMPOSE[@]}" exec -T client0 curl -fsS --max-time 5 "http://$VIP/" 2>/dev/null) || body=""
# whoami answers with "Hostname: <pod>", which in Kubernetes is the pod's own
# name. That is the difference between "something answered" and "a pod behind
# this Service answered"; `kubectl get pods -o wide` above maps it to a node.
host=$(printf '%s' "$body" | sed -n 's/^Hostname: //p' | head -1)
case "$host" in
  demo46-probe-*) row ok "client0 reaches $VIP" "answered by $host" ;;
  *)              row fail "client0 reaches $VIP" "body=[$(printf '%s' "${body:-empty}" | head -1)]" ;;
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
