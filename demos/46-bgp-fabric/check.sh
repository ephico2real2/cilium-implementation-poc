#!/usr/bin/env bash
# check.sh — demo 46 PASS/FAIL/WARN rows (16). Exit = FAIL count. At most 16 rows.
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

# 14. dashboard reachable, 4/4 routers polled
dash_raw=""
dash_rc=0
dash_raw=$(curl -fsS --max-time 3 http://127.0.0.1:8088/api/state 2>&1) || dash_rc=$?
if [ "$dash_rc" -ne 0 ]; then
  row fail "dashboard reachable, 4/4 routers polled" "curl rc=$dash_rc" \
    "D8 — /api/state from 127.0.0.1:8088"
else
  dash_line=""
  dash_py=0
  dash_line=$(printf '%s' "$dash_raw" | python3 scripts/fabric-dashboard-state.py) || dash_py=$?
  if [ "$dash_py" -eq 0 ]; then
    row ok "dashboard reachable, 4/4 routers polled" "$dash_line" \
      "D8 — /api/state from 127.0.0.1:8088"
  else
    row fail "dashboard reachable, 4/4 routers polled" "${dash_line:-parse-fail}" \
      "D8 — /api/state from 127.0.0.1:8088"
  fi
fi

# 15. dashboard sessions agree with vtysh (6 fabric Established)
agree_ok=1
agree_msg=""
if [ "$dash_rc" -ne 0 ]; then
  agree_ok=0
  agree_msg="no /api/state"
elif ! agree_msg=$(printf '%s' "$dash_raw" | python3 -c '
import json, sys
# The six fabric sessions as records, (router, peer) -> peer ASN. The counters
# alone proved nothing (measured 2026-09-20: established 6 / sessionCount 6
# with "sessions": [] passed).
expected = {
    ("edge", "10.200.1.18"): 65100,
    ("spine", "10.200.1.2"): 65101,
    ("spine", "10.200.1.10"): 65102,
    ("spine", "10.200.1.19"): 65000,
    ("leaf1", "10.200.1.3"): 65100,
    ("leaf2", "10.200.1.11"): 65100,
}
try:
    data = json.loads(sys.stdin.read())
except ValueError:
    raise SystemExit("not JSON")
sessions = data.get("sessions") if isinstance(data, dict) else None
if not isinstance(sessions, list):
    raise SystemExit("no session records")
seen = {}
for sess in sessions:
    if isinstance(sess, dict):
        key = (sess.get("router"), sess.get("peer"))
        if key in expected:
            seen[key] = sess
missing = [k for k in expected if k not in seen]
if missing:
    raise SystemExit("dashboard lacks " + ",".join("%s/%s" % k for k in missing))
bad = [k for k, sess in seen.items()
       if sess.get("state") != "Established" or sess.get("stale")
       or sess.get("peerAsn") != expected[k]]
if bad:
    raise SystemExit("dashboard not Established: " + ",".join("%s/%s" % k for k in bad))
if data.get("established") != 6 or data.get("sessionCount") != 6:
    raise SystemExit("dashboard counters %s/%s" % (data.get("established"), data.get("sessionCount")))
print("6/6")
' 2>&1 | tr '\n' ' ' | head -c 80); then
  agree_ok=0
  agree_msg=${agree_msg:-dashboard not 6/6}
fi
if [ "$agree_ok" -eq 1 ]; then
  if ! expect_sessions edge 10.200.1.18 >/dev/null 2>&1 \
     || ! expect_sessions spine 10.200.1.2 10.200.1.10 10.200.1.19 >/dev/null 2>&1 \
     || ! expect_sessions leaf1 10.200.1.3 >/dev/null 2>&1 \
     || ! expect_sessions leaf2 10.200.1.11 >/dev/null 2>&1; then
    agree_ok=0
    agree_msg="vtysh not 6/6"
  fi
fi
if [ "$agree_ok" -eq 1 ]; then
  row ok "dashboard sessions agree with vtysh" "6/6 = 6/6" \
    "D17 — state Established matches fabric-bgp-summary"
else
  row fail "dashboard sessions agree with vtysh" "$agree_msg" \
    "D17 — state Established matches fabric-bgp-summary"
fi

# 16. agent on mgmt only, show-only (dashboard wget; client0 cannot reach)
http_code() {
  # busybox wget -S prints every header line indented, the status line FIRST, and
  # on an error repeats it last as "wget: server returned error: HTTP/1.1 404 Not
  # Found". Take the first status line only: a later header that merely contains
  # an HTTP-like token must not override it (measured 2026-09-20: "X-Debug:
  # HTTP/1.1 404" turned a 200 into 404), and the three digits must end at a
  # boundary ("HTTP/1.1 4040" is not 404). Never a positional field ($2 was "server").
  printf '%s\n' "$1" | awk '
    !seen && /^[[:space:]]*HTTP\/[0-9.]+ [0-9][0-9][0-9]([[:space:]]|$)/ {
      match($0, /HTTP\/[0-9.]+ [0-9][0-9][0-9]/)
      c = substr($0, RSTART + RLENGTH - 3, 3)
      seen = 1
    }
    END { print c + 0 }'
}
ports_raw=""
ports_rc=0
ports_raw=$("${COMPOSE[@]}" ps --format json 2>&1) || ports_rc=$?
ports_ok=0
if [ "$ports_rc" -eq 0 ]; then
  if printf '%s\n' "$ports_raw" | python3 -c '
import json, sys
# `compose ps --format json` is one object per line on v2.21+ (measured v5.5.1:
# "Publishers": [] on a router with no published port) and an array on older
# releases. All four routers must be listed, each with an empty port field:
# garbage, [] or a three-router inventory proves nothing (measured 2026-09-20).
raw = sys.stdin.read()
objs = []
try:
    parsed = json.loads(raw)
    if isinstance(parsed, list):
        objs = parsed
    elif isinstance(parsed, dict):
        objs = [parsed]
except json.JSONDecodeError:
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            objs.append(json.loads(line))
        except json.JSONDecodeError:
            continue
expected = {"edge", "spine", "leaf1", "leaf2"}
seen = set()
published = []
for o in objs:
    if not isinstance(o, dict):
        continue
    name = str(o.get("Service") or o.get("Name") or "")
    svc = name.replace("bgp-fabric-", "").rsplit("-", 1)[0] if name else ""
    if svc not in expected:
        continue
    seen.add(svc)
    if "Publishers" not in o and "Ports" not in o:
        published.append("%s:no-port-field" % svc)
        continue
    pubs = o.get("Publishers")
    if pubs is None:
        pubs = o.get("Ports") or []
    if isinstance(pubs, str) and pubs.strip() and pubs.strip() != "[]":
        published.append("%s:%s" % (svc, pubs))
    elif isinstance(pubs, list):
        for p in pubs:
            if isinstance(p, dict) and (p.get("PublishedPort") or p.get("URL")):
                published.append("%s:%s" % (svc, p.get("PublishedPort") or p.get("URL")))
            elif isinstance(p, str) and p.strip():
                published.append("%s:%s" % (svc, p))
missing = sorted(expected - seen)
if missing:
    print("inventory lacks " + ",".join(missing))
    raise SystemExit(1)
if published:
    print("published " + ",".join(published[:4]))
    raise SystemExit(1)
print("no published ports")
' >/dev/null 2>&1; then
    ports_ok=1
  fi
fi
# wget's own exit status is part of the verdict (busybox exits 1 on a 4xx/5xx
# and on a body that never finishes), and -T bounds an agent that accepts and
# never answers (busybox's default read timeout is 900 s).
reboot_out=""
sum_out=""
reboot_rc=0
sum_rc=0
reboot_out=$("${COMPOSE[@]}" exec -T dashboard wget -q -S -T 5 -O /dev/null \
  'http://10.200.200.11:8080/show/bgp-summary%3Breboot' 2>&1) || reboot_rc=$?
sum_out=$("${COMPOSE[@]}" exec -T dashboard wget -q -S -T 5 -O /dev/null \
  'http://10.200.200.11:8080/show/bgp-summary' 2>&1) || sum_rc=$?
reboot_code=$(http_code "$reboot_out")
sum_code=$(http_code "$sum_out")
# Every management address, not just a far one. The FORWARD drop in
# fabric/entrypoint.sh stops transit onto the mgmt LAN, but a packet
# addressed to a router's OWN management IP is delivered locally and never
# reaches FORWARD: measured 2026-09-20, client0 read the edge's whole table
# on 10.200.200.1 while 10.200.200.11 timed out. 7 = refused, 28 = timed out;
# any other code is a probe that did not run and proves nothing.
client_blocked=0
client_rcs=""
for magent in 10.200.200.1 10.200.200.2 10.200.200.11 10.200.200.12; do
  client_rc=0
  "${COMPOSE[@]}" exec -T client0 curl --max-time 3 -s -o /dev/null \
    "http://$magent:8080/healthz" >/dev/null 2>&1 || client_rc=$?
  client_rcs="${client_rcs:+$client_rcs,}$client_rc"
  if [ "$client_rc" -eq 7 ] || [ "$client_rc" -eq 28 ]; then
    client_blocked=$((client_blocked + 1))
  fi
done
if [ "$ports_ok" -eq 1 ] \
   && [ "$reboot_code" = 404 ] && [ "$reboot_rc" -ne 0 ] \
   && [ "$sum_code" = 200 ] && [ "$sum_rc" -eq 0 ] \
   && [ "$client_blocked" -eq 4 ]; then
  row ok "agent on mgmt only, show-only" \
    "no ports; ;reboot=$reboot_code summary=$sum_code; client0_rc=$client_rcs" \
    "D8 — agent on 10.200.200.0/24, show-only"
else
  row fail "agent on mgmt only, show-only" \
    "ports_ok=$ports_ok ;reboot=${reboot_code:-?}/$reboot_rc summary=${sum_code:-?}/$sum_rc client0_rc=$client_rcs" \
    "D8 — agent on 10.200.200.0/24, show-only"
fi
echo
echo "demo 46 check: $fails FAIL"
exit "$fails"
