#!/usr/bin/env bash
# test: demo 46 check.sh must not PASS on a look-alike (PATH-stub docker and curl).
#   (d) `frr defaults datacenter` (RFC 8212 OFF, nothing printed in the
#       running-config — bgp_vty.c FRR_CFG_DEFAULT_BOOL(BGP_EBGP_REQUIRES_POLICY))
#       → the "RFC 8212 in effect" row is FAIL
#   (e) `seq 10 deny …` → the per-cluster / EG-VIPS prefix-list row is FAIL
#   (f) leaf logs carrying "Unable to set TCP MD5 option" → a WARN row that names
#       TCP_MD5SIG; clean logs → PASS; unreadable logs → FAIL
#   listen stub: only 172.19.0.0/17 → the listen row is FAIL
#   rows 14–16 (the dashboard and the agent), measured 2026-09-20:
#     a one-router /api/state with the counters 6/6 and no session records → 14 and 15 FAIL
#     four routers, counters 6/6, sessions [] (or one stale) → 15 FAIL
#     a status line followed by a header that merely contains "HTTP/1.1 nnn" → the
#       FIRST status line decides (busybox prints the real one first)
#     "HTTP/1.1 4040" is not 404; a wget that exits non-zero after a 200 is not a 200
#     `docker compose ps --format json` printing garbage, [] or three routers → 16 FAIL
#     every dashboard wget carries a read timeout (-T)
#     client0 reaching the ADJACENT router's own mgmt IP (the others blocked) → 16 FAIL
#     a snapshot whose ts is 60 s old → 14 FAIL (a frozen dashboard proves nothing)
# usage: bash tests/check46-false-pass.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/46-bgp-fabric/fabric" "$T/repo/scripts"
cp "$R/demos/46-bgp-fabric/check.sh" "$T/repo/demos/46-bgp-fabric/check.sh"
cp "$R/scripts/fabric-bgp-summary.py" "$T/repo/scripts/fabric-bgp-summary.py"
cp "$R/scripts/fabric-dashboard-state.py" "$T/repo/scripts/fabric-dashboard-state.py"
printf 'name: bgp-fabric\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.yaml"
printf 'name: overlay\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.lan-eg.yaml"

# A healthy fabric, with knobs: STUB_PROFILE, STUB_PL_ACTION, STUB_LOGS, STUB_LISTEN,
# STUB_PORTS, STUB_AGENT_REBOOT, STUB_AGENT_REBOOT_TRAILER, STUB_AGENT_SUM,
# STUB_AGENT_SUM_TRAILER, STUB_AGENT_SUM_RC, STUB_CLIENT0_AGENT, STUB_CLIENT0_EDGE. A dashboard wget
# without -T is recorded in $STUB_MARK.
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'ps --format json'*)
    case "${STUB_PORTS:-healthy}" in
      garbage) echo garbage; exit 0 ;;
      empty)   echo '[]'; exit 0 ;;
      three)   svcs="edge spine leaf1 client0 dashboard" ;;
      *)       svcs="edge spine leaf1 leaf2 client0 dashboard" ;;
    esac
    for s in $svcs; do
      printf '{"Name":"bgp-fabric-%s-1","Service":"%s","Publishers":[]}\n' "$s" "$s"
    done
    exit 0 ;;
  *'ps --format'*)
    for s in edge spine leaf1 leaf2 client0; do echo "bgp-fabric-$s-1 running"; done; exit 0 ;;
  *'ps -q leaf1'*) echo cid-leaf1; exit 0 ;;
  *'ps -q leaf2'*) echo cid-leaf2; exit 0 ;;
  *'show bgp summary json'*)
    cat <<'JSON'
{"ipv4Unicast":{"peers":{
  "10.200.1.18":{"state":"Established","remoteAs":65100},
  "10.200.1.2":{"state":"Established","remoteAs":65101},
  "10.200.1.10":{"state":"Established","remoteAs":65102},
  "10.200.1.19":{"state":"Established","remoteAs":65000},
  "10.200.1.3":{"state":"Established","remoteAs":65100},
  "10.200.1.11":{"state":"Established","remoteAs":65100}
}}}
JSON
    exit 0 ;;
  *'show ip route 10.200.100.0/24'*)
    printf 'Routing entry for 10.200.100.0/24\n  * 10.200.1.3, via eth0\n'; exit 0 ;;
  *'show running-config'*)
    pl=${STUB_PL_ACTION:-permit}
    printf 'frr defaults %s\n' "${STUB_PROFILE:-traditional}"
    printf 'router bgp 65100\n'
    printf ' maximum-paths 8\n'
    printf ' neighbor SERVERS maximum-prefix 64\n'
    printf ' neighbor SERVERS timers 3 9\n'
    printf ' bgp listen range 172.19.0.0/17 peer-group SERVERS\n'
    if [ "${STUB_LISTEN:-both}" != one ]; then
      printf ' bgp listen range 172.18.0.0/17 peer-group SERVERS\n'
    fi
    printf 'ip prefix-list EG-VIPS seq 10 %s 10.98.0.0/24 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list EG-POC1-VIPS seq 10 %s 10.98.0.0/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list EG-POC2-VIPS seq 10 %s 10.98.0.64/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list EG-ANYCAST-VIPS seq 10 %s 10.98.0.192/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list CILIUM-POC1-VIPS seq 10 %s 10.99.0.0/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list CILIUM-POC2-VIPS seq 10 %s 10.99.0.64/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list CILIUM-ANYCAST-VIPS seq 10 %s 10.99.0.192/26 ge 32 le 32\n' "$pl"
    exit 0 ;;
  *'show ip prefix-list'*)
    printf 'BGP: ip prefix-list EG-VIPS: 1 entries\n   seq 10 %s 10.98.0.0/24 le 32\n' "${STUB_PL_ACTION:-permit}"
    exit 0 ;;
  *'logs'*)
    case "${STUB_LOGS:-clean}" in
      refused) echo 'BGP: [NWGVJ-FEW9F][EC 33554495] Unable to set TCP MD5 option on socket for peer 172.19.0.0 (sock=23): Protocol not available'; exit 0 ;;
      broken)  echo 'no such service' >&2; exit 1 ;;
      *)       echo 'BGP: keepalive'; exit 0 ;;
    esac ;;
  *'exec -T dashboard wget'*)
    case "${*#*wget}" in *' -T '*) ;; *) echo "$*" >> "${STUB_MARK:-/dev/null}" ;; esac
    case "$*" in
      *'bgp-summary%3Breboot'*|*'bgp-summary;reboot'*)
        code=${STUB_AGENT_REBOOT:-404}
        echo "  HTTP/1.1 $code Not Found" >&2
        [ "${STUB_AGENT_REBOOT_TRAILER:-}" = x-debug-404 ] && echo "  X-Debug: HTTP/1.1 404 Not Found" >&2
        case "$code" in 2*) exit 0 ;; esac
        echo "wget: server returned error: HTTP/1.1 $code Not Found" >&2
        exit 1 ;;
      *'/show/bgp-summary'*)
        code=${STUB_AGENT_SUM:-200}
        echo "  HTTP/1.1 $code OK" >&2
        [ "${STUB_AGENT_SUM_TRAILER:-}" = x-debug-200 ] && echo "  X-Debug: HTTP/1.1 200 OK" >&2
        case "$code" in 2*) exit "${STUB_AGENT_SUM_RC:-0}" ;; esac
        echo "wget: server returned error: HTTP/1.1 $code OK" >&2
        exit 1 ;;
    esac
    echo "stub: $*" >&2; exit 1 ;;
  *'exec -T client0 curl'*'10.200.200.1:8080/healthz'*)
    # the adjacent router's OWN management IP: an INPUT path from the data plane
    if [ "${STUB_CLIENT0_EDGE:-fail}" = reach ]; then
      echo ok; exit 0
    fi
    echo "curl: (7) Failed to connect" >&2
    exit 7 ;;
  *'exec -T client0 curl'*'8080/healthz'*)
    if [ "${STUB_CLIENT0_AGENT:-fail}" = reach ]; then
      echo ok; exit 0
    fi
    echo "curl: (7) Failed to connect" >&2
    exit 7 ;;
  *ping*) echo "1 packets transmitted, 1 packets received"; exit 0 ;;
  inspect*) case "$*" in *cid-leaf1) echo 172.19.254.11;; *cid-leaf2) echo 172.19.254.12;; esac; exit 0 ;;
  *) echo "stub: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"

# The host curl reaches only row 14's /api/state (client0's curl runs inside the
# docker stub). STUB_DASH: healthy | one-router | counters-only | stale | down.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'127.0.0.1:8088/api/state'*) ;;
  *) echo "curl stub: $*" >&2; exit 1 ;;
esac
routers='[{"name":"edge","asn":65000,"reachable":true},{"name":"spine","asn":65100,"reachable":true},{"name":"leaf1","asn":65101,"reachable":true},{"name":"leaf2","asn":65102,"reachable":true}]'
fabric='{"router":"edge","peer":"10.200.1.18","peerAsn":65100,"state":"Established"},
{"router":"spine","peer":"10.200.1.2","peerAsn":65101,"state":"Established"},
{"router":"spine","peer":"10.200.1.10","peerAsn":65102,"state":"Established"},
{"router":"spine","peer":"10.200.1.19","peerAsn":65000,"state":"Established"},
{"router":"leaf1","peer":"10.200.1.3","peerAsn":65100,"state":"Established"},
{"router":"leaf2","peer":"10.200.1.11","peerAsn":65100,"state":"Established"}'
servers='{"router":"leaf1","peer":"172.19.0.2","peerAsn":65021,"state":"Established"},
{"router":"leaf2","peer":"172.19.0.2","peerAsn":65021,"state":"Established"}'
# a snapshot carries its poll time; "frozen" is one minute old
if [ "${STUB_DASH:-healthy}" = frozen ]; then
  ts=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
else
  ts=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
fi
case "${STUB_DASH:-healthy}" in
  down) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
  one-router)
    printf '{"reachable":1,"routerCount":1,"established":6,"sessionCount":6,"sessions":[]}\n' ;;
  counters-only)
    printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":6,"sessionCount":6,"serverEstablished":2,"serverSessions":2,"external":1,"sessions":[],"nodes":[],"edges":[],"routes":[]}\n' "$ts" "$routers" ;;
  stale)
    printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":6,"sessionCount":6,"serverEstablished":2,"serverSessions":2,"external":1,"sessions":[%s,%s],"nodes":[],"edges":[],"routes":[]}\n' \
      "$ts" "$routers" "$(printf '%s' "$fabric" | sed '1s/"state":"Established"}/"state":"Established","stale":true}/')" "$servers" ;;
  *)
    printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":6,"sessionCount":6,"serverEstablished":2,"serverSessions":2,"external":1,"sessions":[%s,%s],"nodes":[],"edges":[],"routes":[]}\n' \
      "$ts" "$routers" "$fabric" "$servers" ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"
run() { (cd "$T/repo" && env "$@" PATH="$T/bin:/usr/bin:/bin" STUB_MARK="$T/wget-no-timeout" bash demos/46-bgp-fabric/check.sh 2>/dev/null); }

out=$(run)
printf '%s\n' "$out" | grep -Eq '^  PASS +RFC 8212' || { echo "TEST FAIL: baseline stub must PASS RFC 8212"; printf '%s\n' "$out"; exit 1; }

# (d)
out=$(STUB_PROFILE=datacenter run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +RFC 8212' \
  || { echo "TEST FAIL: frr defaults datacenter passed as RFC 8212 in effect"; printf '%s\n' "$out" | grep 'RFC 8212'; exit 1; }

# (e)
out=$(STUB_PL_ACTION=deny run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +(prefix-list EG-VIPS|per-cluster VIP prefix-lists)' \
  || { echo "TEST FAIL: a deny entry passed as EG-VIPS present"; printf '%s\n' "$out" | grep -E 'EG-VIPS|per-cluster'; exit 1; }

# (f)
out=$(STUB_LOGS=refused run)
printf '%s\n' "$out" | grep -Eq '^  WARN +TCP MD5 in effect.*TCP_MD5SIG' \
  || { echo "TEST FAIL: refused TCP_MD5SIG did not produce a WARN row naming it"; printf '%s\n' "$out" | grep -i 'md5' ; exit 1; }
out=$(STUB_LOGS=clean run)
printf '%s\n' "$out" | grep -Eq '^  PASS +TCP MD5 in effect' \
  || { echo "TEST FAIL: clean logs did not PASS the MD5 row"; exit 1; }
out=$(STUB_LOGS=broken run) ; rc=$?
printf '%s\n' "$out" | grep -Eq '^  FAIL +TCP MD5 in effect' && [ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: unreadable logs did not FAIL the MD5 row"; exit 1; }

# listen stub: only 172.19
out=$(STUB_LISTEN=one run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +SERVERS listen' \
  || { echo "TEST FAIL: a single listen range passed the listen row"; printf '%s\n' "$out" | grep listen; exit 1; }

# rows 14–16: every look-alike below must FAIL the named row; the healthy stub must PASS it.
# Each case is "<VAR=value words>|<row prefix>|<PASS|FAIL>|<what the look-alike is>".
bad=0
while IFS='|' read -r env rowpat want what; do
  [ -z "$rowpat" ] && continue
  # the case's VAR=value words are meant to split
  # shellcheck disable=SC2086
  out=$(run $env)
  if printf '%s\n' "$out" | grep -Eq "^  $want +$rowpat"; then
    continue
  fi
  echo "TEST FAIL: $what — expected $want on '$rowpat'"
  printf '%s\n' "$out" | grep -E "$rowpat" | sed 's/^/    /'
  bad=$((bad + 1))
done <<'CASES'
STUB_DASH=healthy|dashboard reachable, 4/4 routers polled|PASS|healthy four-router state
STUB_DASH=healthy|dashboard sessions agree with vtysh|PASS|healthy four-router state
STUB_DASH=healthy|agent on mgmt only, show-only|PASS|healthy agent probes
STUB_DASH=one-router|dashboard reachable, 4/4 routers polled|FAIL|one router polled, counters 6/6, no session records
STUB_DASH=one-router|dashboard sessions agree with vtysh|FAIL|one router polled, counters 6/6, no session records
STUB_DASH=counters-only|dashboard sessions agree with vtysh|FAIL|four routers, counters 6/6, sessions []
STUB_DASH=stale|dashboard sessions agree with vtysh|FAIL|one fabric session stale, counters still 6/6
STUB_DASH=down|dashboard reachable, 4/4 routers polled|FAIL|dashboard down
STUB_AGENT_REBOOT=200|agent on mgmt only, show-only|FAIL|;reboot answered 200
STUB_AGENT_REBOOT=200 STUB_AGENT_REBOOT_TRAILER=x-debug-404|agent on mgmt only, show-only|FAIL|;reboot 200 with a later header containing HTTP/1.1 404
STUB_AGENT_REBOOT=4040|agent on mgmt only, show-only|FAIL|;reboot status "4040" read as 404
STUB_AGENT_SUM=500 STUB_AGENT_SUM_TRAILER=x-debug-200|agent on mgmt only, show-only|FAIL|summary 500 with a later header containing HTTP/1.1 200
STUB_AGENT_SUM_RC=1|agent on mgmt only, show-only|FAIL|summary printed 200 but wget exited 1
STUB_PORTS=garbage|agent on mgmt only, show-only|FAIL|compose ps printed garbage
STUB_PORTS=empty|agent on mgmt only, show-only|FAIL|compose ps printed []
STUB_PORTS=three|agent on mgmt only, show-only|FAIL|compose ps listed three routers
STUB_CLIENT0_AGENT=reach|agent on mgmt only, show-only|FAIL|client0 can reach the agent
STUB_CLIENT0_EDGE=reach|agent on mgmt only, show-only|FAIL|client0 reading the ADJACENT router's agent (its own mgmt IP over the data plane)
STUB_DASH=frozen|dashboard reachable, 4/4 routers polled|FAIL|a snapshot 60 s old (frozen dashboard)
CASES
if [ -s "$T/wget-no-timeout" ]; then
  echo "TEST FAIL: a dashboard wget ran without -T (busybox waits 900 s on an agent that never answers):"
  sed 's/^/    /' "$T/wget-no-timeout" | sort -u
  bad=$((bad + 1))
fi
[ "$bad" -eq 0 ] || { echo "TEST FAIL: $bad look-alike case(s) above"; exit 1; }

# stdout is header + STATUS + rows + final line only (no helper leaks)
out=$(run)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    '== demo 46'*) ;;
    '  STATUS'*) ;;
    '  PASS '*|'  FAIL '*|'  WARN '*) ;;
    'demo 46 check:'*) ;;
    *)
      echo "TEST FAIL: check.sh leaked helper output: $line"
      printf '%s\n' "$out"
      exit 1
      ;;
  esac
done <<EOF2
$out
EOF2

echo "TEST PASS: datacenter profile → FAIL; deny entry → FAIL; TCP_MD5SIG refused → WARN, clean → PASS, unreadable → FAIL; one listen range → FAIL; rows 14–16: one-router / counters-only / stale state → FAIL, trailing HTTP-like headers and 4040 and a failed wget → FAIL, garbage / [] / three-router inventories → FAIL, ;reboot 200 → FAIL, client0 can reach agent → FAIL, client0 reaching the adjacent router → FAIL, a 60 s old snapshot → FAIL, every dashboard wget carries -T; check stdout is rows only"
exit 0
