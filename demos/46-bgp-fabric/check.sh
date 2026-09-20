#!/usr/bin/env bash
# check.sh — demo 46 PASS/FAIL/WARN rows (13). Exit = FAIL count. At most 16 rows.
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
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -Eq '1 received|1 packets received'; then
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

# 8. ECMP config on spine and both leaves
ecmp_ok=1
ecmp_msg=""
for svc in spine leaf1 leaf2; do
  ecmp_out=$("${COMPOSE[@]}" exec -T "$svc" vtysh -c 'show running-config' 2>&1)
  ecmp_rc=$?
  if [ "$ecmp_rc" -ne 0 ]; then
    ecmp_ok=0
    ecmp_msg="${ecmp_msg}${svc}:vtysh-fail "
    continue
  fi
  if ! printf '%s\n' "$ecmp_out" | grep -Eq '^[[:space:]]*maximum-paths[[:space:]]+8[[:space:]]*$'; then
    ecmp_ok=0
    ecmp_msg="${ecmp_msg}${svc}:no-maximum-paths "
  fi
done
if [ "$ecmp_ok" -eq 1 ]; then
  row ok "ECMP maximum-paths on spine and leaves" "maximum-paths 8" "R5 — maximum-paths 8"
else
  row fail "ECMP maximum-paths on spine and leaves" "$ecmp_msg" "R5 — maximum-paths 8"
fi

# 9. SERVERS listen both /17s + policy on both leaves
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
  if ! printf '%s\n' "$lo" | grep -F -q 'bgp listen range 172.19.0.0/17 peer-group SERVERS' \
     || ! printf '%s\n' "$lo" | grep -F -q 'bgp listen range 172.18.0.0/17 peer-group SERVERS' \
     || ! printf '%s\n' "$lo" | grep -F -q 'maximum-prefix 64' \
     || ! printf '%s\n' "$lo" | grep -E -q 'neighbor SERVERS timers 3 9'; then
    listen_ok=0
    listen_msg="${listen_msg}${leaf}:policy "
  fi
done
if [ "$listen_ok" -eq 1 ]; then
  row ok "SERVERS listen both /17s on both leaves" "leaf1+leaf2" \
    "D5 / §9.1 — listen range on the peer-group"
else
  row fail "SERVERS listen both /17s on both leaves" "$listen_msg" \
    "D5 / §9.1 — listen range on the peer-group"
fi

# 10. per-cluster VIP prefix-lists (exact /32s)
pl_out=$("${COMPOSE[@]}" exec -T leaf1 vtysh -c 'show running-config' 2>&1)
pl_rc=$?
pl_ok=1
if [ "$pl_rc" -ne 0 ]; then
  pl_ok=0
else
  for want in \
    'ip prefix-list EG-POC1-VIPS seq 10 permit 10.98.0.0/26 ge 32 le 32' \
    'ip prefix-list EG-POC2-VIPS seq 10 permit 10.98.0.64/26 ge 32 le 32' \
    'ip prefix-list EG-ANYCAST-VIPS seq 10 permit 10.98.0.192/26 ge 32 le 32' \
    'ip prefix-list CILIUM-POC1-VIPS seq 10 permit 10.99.0.0/26 ge 32 le 32' \
    'ip prefix-list CILIUM-POC2-VIPS seq 10 permit 10.99.0.64/26 ge 32 le 32' \
    'ip prefix-list CILIUM-ANYCAST-VIPS seq 10 permit 10.99.0.192/26 ge 32 le 32' \
    'ip prefix-list EG-VIPS seq 10 permit 10.98.0.0/24 ge 32 le 32'
  do
    if ! printf '%s\n' "$pl_out" | grep -Fxq "$want"; then
      pl_ok=0
      break
    fi
  done
fi
if [ "$pl_rc" -ne 0 ]; then
  row fail "per-cluster VIP prefix-lists" "vtysh failed rc=$pl_rc" \
    "R8 — prefix-list + as-path per cluster"
elif [ "$pl_ok" -eq 1 ]; then
  row ok "per-cluster VIP prefix-lists" "EG/CILIUM POC1/POC2/ANYCAST ge 32 le 32" \
    "R8 — prefix-list + as-path per cluster"
else
  row fail "per-cluster VIP prefix-lists" "exact permit lines absent or not permit" \
    "R8 — prefix-list + as-path per cluster"
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

# 12. RFC 8212: traditional profile + a router bgp line; no policy-off
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
  if ! printf '%s\n' "$cfg" | grep -Eq '^frr defaults traditional[[:space:]]*$' \
     || ! printf '%s\n' "$cfg" | grep -Eq '^router bgp [0-9]+[[:space:]]*$' \
     || printf '%s\n' "$cfg" | grep -F -q 'no bgp ebgp-requires-policy'; then
    rfc_ok=0
    rfc_msg="${rfc_msg}${svc}:policy-unverified "
  fi
done
if [ "$rfc_ok" -eq 1 ]; then
  row ok "RFC 8212 in effect" "traditional profile, ebgp-requires-policy on" \
    "§8 row 5 — traditional defaults, explicit route-maps"
else
  row fail "RFC 8212 in effect" "$rfc_msg" \
    "§8 row 5 — traditional defaults, explicit route-maps"
fi

# 13. TCP MD5 in effect on the leaves. FRR asks the kernel for TCP_MD5SIG per
# neighbour and per listen range; a kernel without CONFIG_TCP_MD5SIG (Docker
# Desktop's linuxkit, measured 2026-09-20) answers ENOPROTOOPT, FRR logs
# "Unable to set TCP MD5 option ... Protocol not available" and the session
# runs UNSIGNED (tcpdump: options [nop,nop,TS], no md5). WARN there, so the
# transcript says so; PASS on a kernel that takes the option; FAIL if the
# logs cannot be read.
md5_state=ok
md5_msg=""
for leaf in leaf1 leaf2; do
  lg=$("${COMPOSE[@]}" logs --no-log-prefix "$leaf" 2>&1)
  lr=$?
  if [ "$lr" -ne 0 ]; then
    md5_state=fail
    md5_msg="${md5_msg}${leaf}:logs-fail "
    continue
  fi
  n=$(printf '%s\n' "$lg" | grep -c 'Unable to set TCP MD5 option')
  if [ "$n" -gt 0 ]; then
    [ "$md5_state" = fail ] || md5_state=warn
    md5_msg="${md5_msg}${leaf}:TCP_MD5SIG-refused=${n} "
  fi
done
case "$md5_state" in
  ok)   row ok   "TCP MD5 in effect on the leaves" "no TCP_MD5SIG refusal logged" \
          "§8 row 3 — the kernel signs every session" ;;
  warn) row warn "TCP MD5 in effect on the leaves" "$md5_msg" \
          "§8 row 3 — no CONFIG_TCP_MD5SIG here: sessions run unsigned" ;;
  *)    row fail "TCP MD5 in effect on the leaves" "$md5_msg" \
          "§8 row 3 — the kernel signs every session" ;;
esac

echo
echo "demo 46 check: $fails FAIL"
exit "$fails"
