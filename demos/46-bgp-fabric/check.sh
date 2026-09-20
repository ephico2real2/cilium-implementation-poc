#!/usr/bin/env bash
# check.sh — demo 46 PASS/FAIL rows. Exit = FAIL count. At most 16 rows.
# A dead docker/vtysh is a FAIL, never a PASS. Session state is an exact
# JSON field match (Established), never a substring of the blob.
#   demos/46-bgp-fabric/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
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

FABRIC=demos/46-bgp-fabric/fabric
PROJECT=bgp-fabric
COMPOSE=(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml")

printf '\n== demo 46 — the BGP fabric (four FRR routers, Envoy overlay)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# 1. four routers running
ps_out=$("${COMPOSE[@]}" ps --format '{{.Name}} {{.State}}' 2>&1)
ps_rc=$?
if [ "$ps_rc" -ne 0 ]; then
  row fail "four routers running" "docker failed: $(printf '%s' "$ps_out" | tr '\n' ' ' | head -c 60)" \
    "R1 — edge spine leaf1 leaf2 running"
else
  n=0
  for svc in edge spine leaf1 leaf2; do
    if printf '%s\n' "$ps_out" | grep -Eq "${PROJECT}-${svc}-[0-9]+ running"; then
      n=$((n + 1))
    fi
  done
  if [ "$n" -eq 4 ]; then
    row ok "four routers running" "running=$n/4" "R1 — edge spine leaf1 leaf2 running"
  else
    row fail "four routers running" "running=$n/4" "R1 — edge spine leaf1 leaf2 running"
  fi
fi

# 2. six fabric sessions Established (both directions, from the summaries)
expect_sessions() {
  local raw rc=0
  raw=$("${COMPOSE[@]}" exec -T "$1" vtysh -c 'show bgp summary json' 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "vtysh-fail:$1"
    return 1
  fi
  shift
  if ! printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py --require "$@"; then
    echo "not-established:$1"
    return 1
  fi
  return 0
}
sess_err=""
if ! e=$(expect_sessions edge 10.200.1.18 2>&1); then
  sess_err="edge:${e:-fail}"
elif ! e=$(expect_sessions spine 10.200.1.2 10.200.1.10 10.200.1.19 2>&1); then
  sess_err="spine:${e:-fail}"
elif ! e=$(expect_sessions leaf1 10.200.1.3 2>&1); then
  sess_err="leaf1:${e:-fail}"
elif ! e=$(expect_sessions leaf2 10.200.1.11 2>&1); then
  sess_err="leaf2:${e:-fail}"
fi
if [ -z "$sess_err" ]; then
  row ok "six fabric sessions Established" "6/6 Established" \
    "R1 — leaf1–spine, leaf2–spine, spine–edge, both directions"
else
  row fail "six fabric sessions Established" "$sess_err" \
    "R1 — leaf1–spine, leaf2–spine, spine–edge, both directions"
fi

# 3–6. loopbacks from client0
ping_lo() { # ip
  local ip=$1 out rc=0
  out=$("${COMPOSE[@]}" exec -T client0 ping -c 1 -W 2 "$ip" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    row fail "client0 ping $ip" "docker/ping rc=$rc" "R1 — loopback reachable from client0"
  else
    row ok "client0 ping $ip" "rc=0" "R1 — loopback reachable from client0"
  fi
}
ping_lo 10.200.255.1
ping_lo 10.200.255.2
ping_lo 10.200.255.11
ping_lo 10.200.255.12

# 7. wan in leaf1 via spine (10.200.1.3)
route_out=$("${COMPOSE[@]}" exec -T leaf1 vtysh -c 'show ip route 10.200.100.0/24' 2>&1)
route_rc=$?
if [ "$route_rc" -ne 0 ]; then
  row fail "10.200.100.0/24 in leaf1 via spine" "vtysh failed rc=$route_rc" \
    "R1 — wan learned via 10.200.1.3"
elif printf '%s\n' "$route_out" | grep -F -q '10.200.100.0/24' \
  && printf '%s\n' "$route_out" | grep -F -q '10.200.1.3'; then
  row ok "10.200.100.0/24 in leaf1 via spine" "via 10.200.1.3" \
    "R1 — wan learned via 10.200.1.3"
else
  row fail "10.200.100.0/24 in leaf1 via spine" "prefix or nexthop absent" \
    "R1 — wan learned via 10.200.1.3"
fi

# 8. ECMP config on spine
ecmp_out=$("${COMPOSE[@]}" exec -T spine vtysh -c 'show running-config' 2>&1)
ecmp_rc=$?
if [ "$ecmp_rc" -ne 0 ]; then
  row fail "ECMP maximum-paths on spine" "vtysh failed rc=$ecmp_rc" \
    "R5 — maximum-paths 8"
elif printf '%s\n' "$ecmp_out" | grep -Eq '^[[:space:]]*maximum-paths[[:space:]]+8[[:space:]]*$'; then
  row ok "ECMP maximum-paths on spine" "maximum-paths 8" "R5 — maximum-paths 8"
else
  row fail "ECMP maximum-paths on spine" "maximum-paths 8 absent" "R5 — maximum-paths 8"
fi

# 9. SERVERS listen 172.19.0.0/17 on both leaves
listen_ok=1
listen_msg=""
for leaf in leaf1 leaf2; do
  lo=$("${COMPOSE[@]}" exec -T "$leaf" vtysh -c 'show running-config' 2>&1)
  lr=$?
  if [ "$lr" -ne 0 ]; then
    listen_ok=0
    listen_msg="${listen_msg}${leaf}:vtysh-fail "
    continue
  fi
  if ! printf '%s\n' "$lo" | grep -F -q 'bgp listen range 172.19.0.0/17 peer-group SERVERS'; then
    listen_ok=0
    listen_msg="${listen_msg}${leaf}:no-listen "
  fi
done
if [ "$listen_ok" -eq 1 ]; then
  row ok "SERVERS listen 172.19.0.0/17 on both leaves" "leaf1+leaf2" \
    "D5 / §9.1 — listen range on the peer-group"
else
  row fail "SERVERS listen 172.19.0.0/17 on both leaves" "$listen_msg" \
    "D5 / §9.1 — listen range on the peer-group"
fi

# 10. EG-VIPS prefix-list
pl_out=$("${COMPOSE[@]}" exec -T leaf1 vtysh -c 'show ip prefix-list EG-VIPS' 2>&1)
pl_rc=$?
if [ "$pl_rc" -ne 0 ]; then
  row fail "prefix-list EG-VIPS present" "vtysh failed rc=$pl_rc" \
    "R8 — EG-VIPS permit 10.98.0.0/24 le 32"
elif printf '%s\n' "$pl_out" | grep -F -q '10.98.0.0/24'; then
  row ok "prefix-list EG-VIPS present" "10.98.0.0/24" \
    "R8 — EG-VIPS permit 10.98.0.0/24 le 32"
else
  row fail "prefix-list EG-VIPS present" "10.98.0.0/24 absent" \
    "R8 — EG-VIPS permit 10.98.0.0/24 le 32"
fi

# 11. leaves on kind-eg at .11/.12
ip11=""
ip12=""
cid1=$("${COMPOSE[@]}" ps -q leaf1 2>&1)
rc1=$?
cid2=$("${COMPOSE[@]}" ps -q leaf2 2>&1)
rc2=$?
if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ -z "$cid1" ] || [ -z "$cid2" ]; then
  row fail "leaves on kind-eg 172.19.254.11/.12" "docker ps failed" \
    "§9.1 — 172.19.254.11/.12"
else
  ip11=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "$cid1" 2>&1) || ip11=""
  ip12=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "$cid2" 2>&1) || ip12=""
  if [ "$ip11" = 172.19.254.11 ] && [ "$ip12" = 172.19.254.12 ]; then
    row ok "leaves on kind-eg 172.19.254.11/.12" "leaf1=$ip11 leaf2=$ip12" \
      "§9.1 — 172.19.254.11/.12"
  else
    row fail "leaves on kind-eg 172.19.254.11/.12" "leaf1=${ip11:-?} leaf2=${ip12:-?}" \
      "§9.1 — 172.19.254.11/.12"
  fi
fi

# 12. RFC 8212: no `no bgp ebgp-requires-policy` on any router
rfc_ok=1
rfc_msg=""
for svc in edge spine leaf1 leaf2; do
  cfg=$("${COMPOSE[@]}" exec -T "$svc" vtysh -c 'show running-config' 2>&1)
  cr=$?
  if [ "$cr" -ne 0 ]; then
    rfc_ok=0
    rfc_msg="${rfc_msg}${svc}:vtysh-fail "
    continue
  fi
  if printf '%s\n' "$cfg" | grep -F -q 'no bgp ebgp-requires-policy'; then
    rfc_ok=0
    rfc_msg="${rfc_msg}${svc}:policy-off "
  fi
done
if [ "$rfc_ok" -eq 1 ]; then
  row ok "RFC 8212 in effect" "no ebgp-requires-policy disabled" \
    "§8 row 5 — traditional defaults, explicit route-maps"
else
  row fail "RFC 8212 in effect" "$rfc_msg" \
    "§8 row 5 — traditional defaults, explicit route-maps"
fi

echo
echo "demo 46 check: $fails FAIL"
exit "$fails"
