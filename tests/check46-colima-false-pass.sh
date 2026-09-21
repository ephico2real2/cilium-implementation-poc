#!/usr/bin/env bash
# test: demo 46-colima check.sh must not PASS on a look-alike (PATH-stub).
#   (d) frr defaults datacenter → RFC 8212 FAIL
#   (e) seq 10 deny → prefix-list FAIL
#   listen stub: only 172.19.0.0/17 (Desktop LAN) → listen FAIL
#   MD5: zero wire packets FAIL; missing CONFIG_TCP_MD5SIG FAIL;
#        mismatch that stays Established FAIL; restore-fail FAIL
#   dashboard / agent look-alikes as in check46-false-pass.sh
# usage: bash tests/check46-colima-false-pass.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/46-bgp-fabric-colima/fabric" "$T/repo/scripts/bootstrap"
cp "$R/demos/46-bgp-fabric-colima/check.sh" "$T/repo/demos/46-bgp-fabric-colima/check.sh"
cp "$R/scripts/fabric-bgp-summary.py" "$T/repo/scripts/fabric-bgp-summary.py"
cp "$R/scripts/fabric-dashboard-state.py" "$T/repo/scripts/fabric-dashboard-state.py"
cp "$R/scripts/fabric-dashboard-agree.py" "$T/repo/scripts/fabric-dashboard-agree.py"
cp "$R/scripts/fabric-colima-lib.sh" "$T/repo/scripts/fabric-colima-lib.sh"
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/versions-eg.env"
printf 'name: bgp-fabric-colima\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/compose.yaml"
printf 'FABRIC_BGP_PASSWORD=lab-bgp\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/.env"

# STUB_PW_STATE: established | dropped  (mismatch row)
# STUB_RESTORE: ok | fail
# STUB_TCPDUMP: signed | unsigned | fail
# STUB_KERNEL: y | absent | fail
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'context inspect'*) echo '{}'; exit 0 ;;
  *' info'*) echo ok; exit 0 ;;
  *'ps --format json'*)
    case "${STUB_PORTS:-healthy}" in
      garbage) echo garbage; exit 0 ;;
      empty)   echo '[]'; exit 0 ;;
      three)   svcs="edge spine leaf1 client0 dashboard" ;;
      *)       svcs="edge spine leaf1 leaf2 client0 dashboard" ;;
    esac
    for s in $svcs; do
      printf '{"Name":"bgp-fabric-colima-%s-1","Service":"%s","Publishers":[]}\n' "$s" "$s"
    done
    exit 0 ;;
  *'ps --format'*)
    for s in edge spine leaf1 leaf2 client0; do echo "bgp-fabric-colima-$s-1 running"; done; exit 0 ;;
  *'ps -q leaf1'*) echo cid-leaf1; exit 0 ;;
  *'ps -q leaf2'*) echo cid-leaf2; exit 0 ;;
  *'show bgp summary json'*)
    leaf1_state=Established
    if [ -f "${STUB_DIR:-/tmp}/pw" ] && [ ! -f "${STUB_DIR:-/tmp}/restored" ]; then
      leaf1_state=Connect
    fi
    if [ "${STUB_PW_STATE:-established}" = dropped ]; then
      leaf1_state=Connect
    fi
    if [ -f "${STUB_DIR:-/tmp}/restored" ]; then
      leaf1_state=Established
    fi
    printf '{"ipv4Unicast":{"peers":{
  "10.200.1.18":{"state":"Established","remoteAs":65100},
  "10.200.1.2":{"state":"Established","remoteAs":65101},
  "10.200.1.10":{"state":"Established","remoteAs":65102},
  "10.200.1.19":{"state":"Established","remoteAs":65000},
  "10.200.1.3":{"state":"%s","remoteAs":65100},
  "10.200.1.11":{"state":"Established","remoteAs":65100}
}}}\n' "$leaf1_state"
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
    if [ "${STUB_LISTEN:-colima}" = old ]; then
      printf ' bgp listen range 172.19.0.0/17 peer-group SERVERS\n'
      printf ' bgp listen range 172.18.0.0/17 peer-group SERVERS\n'
    else
      printf ' bgp listen range 172.20.0.0/17 peer-group SERVERS\n'
    fi
    printf 'ip prefix-list EG-VIPS seq 10 %s 10.198.0.0/24 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list EG-POC1-VIPS seq 10 %s 10.198.0.0/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list EG-POC2-VIPS seq 10 %s 10.198.0.64/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list EG-ANYCAST-VIPS seq 10 %s 10.198.0.192/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list CILIUM-POC1-VIPS seq 10 %s 10.199.0.0/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list CILIUM-POC2-VIPS seq 10 %s 10.199.0.64/26 ge 32 le 32\n' "$pl"
    printf 'ip prefix-list CILIUM-ANYCAST-VIPS seq 10 %s 10.199.0.192/26 ge 32 le 32\n' "$pl"
    exit 0 ;;
  *'configure terminal'*password*)
    case "$*" in
      *wrong-colima-md5*)
        if [ "${STUB_MISMATCH:-drop}" = stay ]; then
          echo "password set (session stays Established)"; exit 0
        fi
        echo dropped > "${STUB_DIR:-/tmp}/pw"
        exit 0 ;;
      *lab-bgp*)
        if [ "${STUB_RESTORE:-ok}" = fail ]; then
          echo "vtysh restore failed" >&2; exit 1
        fi
        echo restored > "${STUB_DIR:-/tmp}/restored"
        exit 0 ;;
    esac
    echo "stub vtysh: $*"; exit 1 ;;
  *'run '*tcpdump*|*' timeout 15 tcpdump'*)
    case "${STUB_TCPDUMP:-signed}" in
      fail) echo "tcpdump: no such device" >&2; exit 1 ;;
      unsigned)
        echo "  10.200.1.2.179 > 10.200.1.3.51234: Flags [P.], options [nop,nop,TS], length 19"
        exit 0 ;;
      *)
        echo "  10.200.1.2.179 > 10.200.1.3.51234: Flags [P.], options [md5valid], length 19"
        echo "  10.200.1.3.51234 > 10.200.1.2.179: Flags [P.], options [md5valid], length 19"
        exit 0 ;;
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
    if [ "${STUB_CLIENT0_EDGE:-fail}" = reach ]; then echo ok; exit 0; fi
    echo "curl: (7) Failed to connect" >&2; exit 7 ;;
  *'exec -T client0 curl'*'8080/healthz'*)
    if [ "${STUB_CLIENT0_AGENT:-fail}" = reach ]; then echo ok; exit 0; fi
    echo "curl: (7) Failed to connect" >&2; exit 7 ;;
  *ping*) echo "1 packets transmitted, 1 packets received"; exit 0 ;;
  *) echo "stub: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"

cat > "$T/bin/colima" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *ssh*)
    case "${STUB_KERNEL:-y}" in
      fail) echo "ssh failed" >&2; exit 1 ;;
      absent) echo "6.8.0-117-generic"; exit 0 ;;
      *) echo "6.8.0-117-generic"; echo "CONFIG_TCP_MD5SIG=y"; exit 0 ;;
    esac ;;
  *) echo "stub colima: $*"; exit 1 ;;
esac
STUB
chmod +x "$T/bin/colima"

cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'127.0.0.1:8098/api/state'*) ;;
  *) echo "curl stub: $*" >&2; exit 1 ;;
esac
routers='[{"name":"edge","asn":65000,"reachable":true},{"name":"spine","asn":65100,"reachable":true},{"name":"leaf1","asn":65101,"reachable":true},{"name":"leaf2","asn":65102,"reachable":true}]'
fabric='{"router":"edge","peer":"10.200.1.18","peerAsn":65100,"state":"Established"},
{"router":"spine","peer":"10.200.1.2","peerAsn":65101,"state":"Established"},
{"router":"spine","peer":"10.200.1.10","peerAsn":65102,"state":"Established"},
{"router":"spine","peer":"10.200.1.19","peerAsn":65000,"state":"Established"},
{"router":"leaf1","peer":"10.200.1.3","peerAsn":65100,"state":"Established"},
{"router":"leaf2","peer":"10.200.1.11","peerAsn":65100,"state":"Established"}'
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
    printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":6,"sessionCount":6,"serverEstablished":0,"serverSessions":0,"external":0,"sessions":[],"nodes":[],"edges":[],"routes":[]}\n' "$ts" "$routers" ;;
  stale)
    printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":6,"sessionCount":6,"serverEstablished":0,"serverSessions":0,"external":0,"sessions":[%s],"nodes":[],"edges":[],"routes":[]}\n' \
      "$ts" "$routers" "$(printf '%s' "$fabric" | sed '1s/"state":"Established"}/"state":"Established","stale":true}/')" ;;
  *)
    printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":6,"sessionCount":6,"serverEstablished":0,"serverSessions":0,"external":0,"sessions":[%s],"nodes":[],"edges":[],"routes":[]}\n' \
      "$ts" "$routers" "$fabric" ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"

run() {
  rm -f "$T/restored" "$T/pw"
  (cd "$T/repo" && env "$@" PATH="$T/bin:/usr/bin:/bin" STUB_MARK="$T/wget-no-timeout" STUB_DIR="$T" \
    bash demos/46-bgp-fabric-colima/check.sh 2>/dev/null)
}

out=$(run)
printf '%s\n' "$out" | grep -Eq '^  PASS +RFC 8212' || { echo "TEST FAIL: baseline stub must PASS RFC 8212"; printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out" | grep -Eq '^  PASS +sessions signed on the wire' \
  || { echo "TEST FAIL: baseline must PASS wire MD5"; printf '%s\n' "$out" | grep -i md5; exit 1; }
printf '%s\n' "$out" | grep -Eq '^  PASS +a wrong password breaks the session' \
  || { echo "TEST FAIL: baseline must PASS mismatch"; printf '%s\n' "$out" | grep -i password; exit 1; }
printf '%s\n' "$out" | grep -Eq '^  PASS +kernel has CONFIG_TCP_MD5SIG' \
  || { echo "TEST FAIL: baseline must PASS kernel MD5"; printf '%s\n' "$out" | grep kernel; exit 1; }

out=$(STUB_PROFILE=datacenter run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +RFC 8212' \
  || { echo "TEST FAIL: frr defaults datacenter passed as RFC 8212"; exit 1; }

out=$(STUB_PL_ACTION=deny run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +per-cluster VIP prefix-lists' \
  || { echo "TEST FAIL: a deny entry passed as prefix-lists present"; exit 1; }

out=$(STUB_LISTEN=old run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +SERVERS listen' \
  || { echo "TEST FAIL: the Desktop listen ranges passed as Colima's"; exit 1; }

out=$(STUB_TCPDUMP=unsigned run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +sessions signed on the wire' \
  || { echo "TEST FAIL: unsigned tcpdump (0 md5) did not FAIL the wire row"; exit 1; }

out=$(STUB_TCPDUMP=fail run) ; rc=$?
printf '%s\n' "$out" | grep -Eq '^  FAIL +sessions signed on the wire' && [ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: dead tcpdump did not FAIL the wire row"; exit 1; }

out=$(STUB_KERNEL=absent run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +kernel has CONFIG_TCP_MD5SIG' \
  || { echo "TEST FAIL: kernel without CONFIG_TCP_MD5SIG did not FAIL"; exit 1; }

out=$(STUB_MISMATCH=stay run)
printf '%s\n' "$out" | grep -Eq '^  FAIL +a wrong password breaks the session' \
  || { echo "TEST FAIL: session that stayed Established passed the mismatch row"; printf '%s\n' "$out" | grep password; exit 1; }

out=$(STUB_RESTORE=fail run) ; rc=$?
printf '%s\n' "$out" | grep -Eq '^  FAIL +a wrong password breaks the session' && [ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: restore-fail did not FAIL the mismatch row"; exit 1; }

bad=0
while IFS='|' read -r env rowpat want what; do
  [ -z "$rowpat" ] && continue
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
STUB_AGENT_SUM_RC=1|agent on mgmt only, show-only|FAIL|summary printed 200 but wget exited 1
STUB_PORTS=garbage|agent on mgmt only, show-only|FAIL|compose ps printed garbage
STUB_PORTS=empty|agent on mgmt only, show-only|FAIL|compose ps printed []
STUB_PORTS=three|agent on mgmt only, show-only|FAIL|compose ps listed three routers
STUB_CLIENT0_AGENT=reach|agent on mgmt only, show-only|FAIL|client0 can reach the agent
STUB_CLIENT0_EDGE=reach|agent on mgmt only, show-only|FAIL|client0 reading the adjacent router
STUB_DASH=frozen|dashboard reachable, 4/4 routers polled|FAIL|a snapshot 60 s old
CASES
[ "$bad" -eq 0 ] || { echo "TEST FAIL: $bad look-alike case(s)"; exit 1; }

out=$(run)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    '== demo 46-colima'*) ;;
    '  STATUS'*) ;;
    '  PASS '*|'  FAIL '*|'  WARN '*) ;;
    'demo 46-colima check:'*) ;;
    *)
      echo "TEST FAIL: check.sh leaked helper output: $line"
      exit 1
      ;;
  esac
done <<EOF2
$out
EOF2

echo "TEST PASS: datacenter/deny/old-listen FAIL; unsigned/dead tcpdump FAIL; kernel absent FAIL; stay-Established and restore-fail FAIL; dashboard/agent look-alikes FAIL; stdout is rows only"
exit 0
