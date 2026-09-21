#!/usr/bin/env bash
# test: demo 46-colima check.sh — the MD5 rows must not PASS on a look-alike
# that the older rows accepted (PATH-stub; no daemon, no VM).
#   (1) wire row: leaf1's namespace carries the cluster's SERVERS sessions too.
#       Those are signed; the fabric session is NOT. The capture must be tied
#       to the fabric peer, so this FAILs.
#   (2) control row: a wrong key that the peer does not enforce — the session
#       bounces (the config change resets it) and comes back WITH the wrong key
#       still installed. FRR resets on every password change, so a single
#       non-Established sample is not evidence; this must FAIL.
#   (3) restore: fabric/.env no longer holds the key the session is running
#       with. The row must restore the RUNNING key, not the file's, and PASS —
#       a check that leaves the fabric down is worse than a red row.
#   (4) agreement row: /api/state disagrees once, then agrees, while vtysh
#       stays short of 6/6. The retry must re-read both sides → FAIL.
# usage: bash tests/check46-colima-md5-control.sh [path-to-check.sh]
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CHECK=${1:-$R/demos/46-bgp-fabric-colima/check.sh}
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/46-bgp-fabric-colima/fabric" "$T/repo/scripts/bootstrap"
cp "$CHECK" "$T/repo/demos/46-bgp-fabric-colima/check.sh"
for f in fabric-bgp-summary.py fabric-dashboard-state.py fabric-dashboard-agree.py fabric-colima-lib.sh; do
  cp "$R/scripts/$f" "$T/repo/scripts/$f"
done
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/versions-eg.env"
printf 'name: bgp-fabric-colima\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/compose.yaml"
printf 'FABRIC_BGP_PASSWORD=lab-bgp\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/.env"

# the loops are logic, not clocks: a no-op sleep keeps the harness under a minute
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"

cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
D="${STUB_DIR:-/tmp}"
RUN_PW="${STUB_RUNNING_PW:-lab-bgp}"
case "$*" in
  *'context inspect'*) echo '{}'; exit 0 ;;
  *' info'*) echo ok; exit 0 ;;
  *'ps --format json'*)
    for s in edge spine leaf1 leaf2 client0 dashboard; do
      printf '{"Name":"bgp-fabric-colima-%s-1","Service":"%s","Publishers":[]}\n' "$s" "$s"
    done
    exit 0 ;;
  *'ps --format'*)
    for s in edge spine leaf1 leaf2 client0; do echo "bgp-fabric-colima-$s-1 running"; done; exit 0 ;;
  *'ps -q leaf1'*) echo cid-leaf1; exit 0 ;;
  *'show bgp summary json'*)
    st=Established
    if [ -f "$D/pw" ] && [ ! -f "$D/restored" ]; then
      st=Connect
      if [ "${STUB_MISMATCH:-sticky}" = bounce ]; then
        n=$(cat "$D/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$D/polls"
        [ "$n" -gt 2 ] && st=Established     # comes back with the WRONG key
      fi
    fi
    [ "${STUB_VTYSH_SHORT:-0}" = 1 ] && st=Connect
    printf '{"ipv4Unicast":{"peers":{
  "10.200.1.18":{"state":"Established","remoteAs":65100},
  "10.200.1.2":{"state":"Established","remoteAs":65101},
  "10.200.1.10":{"state":"Established","remoteAs":65102},
  "10.200.1.19":{"state":"Established","remoteAs":65000},
  "10.200.1.3":{"state":"%s","remoteAs":65100},
  "10.200.1.11":{"state":"Established","remoteAs":65100}
}}}\n' "$st"
    exit 0 ;;
  *'show ip route 10.200.100.0/24'*)
    printf 'Routing entry for 10.200.100.0/24\n  * 10.200.1.3, via eth0\n'; exit 0 ;;
  *'show running-config'*)
    printf 'frr defaults traditional\n'
    printf 'router bgp 65100\n'
    printf ' maximum-paths 8\n'
    printf ' neighbor 10.200.1.3 remote-as 65100\n'
    printf ' neighbor 10.200.1.3 password %s\n' "$RUN_PW"
    printf ' neighbor SERVERS maximum-prefix 64\n'
    printf ' neighbor SERVERS timers 3 9\n'
    printf ' bgp listen range 172.20.0.0/17 peer-group SERVERS\n'
    for pl in 'EG-VIPS 10.198.0.0/24' 'EG-POC1-VIPS 10.198.0.0/26' 'EG-POC2-VIPS 10.198.0.64/26' \
              'EG-ANYCAST-VIPS 10.198.0.192/26' 'CILIUM-POC1-VIPS 10.199.0.0/26' \
              'CILIUM-POC2-VIPS 10.199.0.64/26' 'CILIUM-ANYCAST-VIPS 10.199.0.192/26'; do
      set -- $pl; printf 'ip prefix-list %s seq 10 permit %s ge 32 le 32\n' "$1" "$2"
    done
    exit 0 ;;
  *'configure terminal'*password*)
    case "$*" in
      *wrong-colima-md5*) echo bad > "$D/pw"; rm -f "$D/polls"; exit 0 ;;
      *"password $RUN_PW"*) echo ok > "$D/restored"; exit 0 ;;   # only the RUNNING key restores it
      *) exit 0 ;;                                               # any other key: accepted, session stays down
    esac ;;
  *tcpdump*)
    # the stub is the kernel here: it answers the filter it was given.
    case "$*" in
      *'host 10.200.1.3'*)
        for i in 1 2 3 4 5; do
          echo "02:26:47.48298$i eth0  Out IP (tos 0xc0, ttl 1, id 1352$i, offset 0, flags [DF], proto TCP (6), length 79)"
          echo "    10.200.1.2.179 > 10.200.1.3.43010: Flags [P.], seq 1:20, ack 1, win 501, options [nop,nop,TS val 1 ecr 1], length 19: BGP"
        done ;;
      *)
        for i in 1 2 3; do
          echo "02:26:47.48298$i eth0  Out IP (tos 0xc0, ttl 1, id 1352$i, offset 0, flags [DF], proto TCP (6), length 79)"
          echo "    10.200.1.2.179 > 10.200.1.3.43010: Flags [P.], seq 1:20, ack 1, win 501, options [nop,nop,TS val 1 ecr 1], length 19: BGP"
        done
        for i in 1 2 3 4 5 6 7; do
          echo "02:27:06.21007$i eth2  Out IP (tos 0xc0, ttl 1, id 900$i, offset 0, flags [DF], proto TCP (6), length 79)"
          echo "    172.20.254.11.179 > 172.20.0.3.56647: Flags [P.], seq 1:20, ack 1, win 502, options [nop,nop,md5 shared secret not supplied with -M, can't check - bca084739e99b0c5e2f0c3938cafadce], length 19: BGP"
        done ;;
    esac
    exit 0 ;;
  *'exec -T dashboard wget'*)
    case "$*" in
      *'bgp-summary%3Breboot'*) echo "  HTTP/1.1 404 Not Found" >&2; exit 1 ;;
      *) echo "  HTTP/1.1 200 OK" >&2; exit 0 ;;
    esac ;;
  *'exec -T client0 curl'*) echo "curl: (7)" >&2; exit 7 ;;
  *ping*) echo "1 packets transmitted, 1 packets received"; exit 0 ;;
  *) echo "stub: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"

printf '#!/usr/bin/env bash\necho "6.8.0-117-generic"; echo "CONFIG_TCP_MD5SIG=y"; exit 0\n' > "$T/bin/colima"
chmod +x "$T/bin/colima"

cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
D="${STUB_DIR:-/tmp}"
case "$*" in *'127.0.0.1:8098/api/state'*) ;; *) exit 1 ;; esac
ts=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
routers='[{"name":"edge","asn":65000,"reachable":true},{"name":"spine","asn":65100,"reachable":true},{"name":"leaf1","asn":65101,"reachable":true},{"name":"leaf2","asn":65102,"reachable":true}]'
fabric='{"router":"edge","peer":"10.200.1.18","peerAsn":65100,"state":"Established"},
{"router":"spine","peer":"10.200.1.2","peerAsn":65101,"state":"Established"},
{"router":"spine","peer":"10.200.1.10","peerAsn":65102,"state":"Established"},
{"router":"spine","peer":"10.200.1.19","peerAsn":65000,"state":"Established"},
{"router":"leaf1","peer":"10.200.1.3","peerAsn":65100,"state":"Established"},
{"router":"leaf2","peer":"10.200.1.11","peerAsn":65100,"state":"Established"}'
if [ "${STUB_DASH:-healthy}" = late ] && [ ! -f "$D/dash-seen" ]; then
  : > "$D/dash-seen"
  printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":5,"sessionCount":6,"serverEstablished":0,"serverSessions":0,"external":0,"sessions":[%s],"nodes":[],"edges":[],"routes":[]}\n' \
    "$ts" "$routers" "$(printf '%s' "$fabric" | sed 's/"router":"leaf1","peer":"10.200.1.3","peerAsn":65100,"state":"Established"/"router":"leaf1","peer":"10.200.1.3","peerAsn":65100,"state":"Connect"/')"
  exit 0
fi
printf '{"ts":"%s","poll":"2s","routers":%s,"reachable":4,"routerCount":4,"established":6,"sessionCount":6,"serverEstablished":0,"serverSessions":0,"external":0,"sessions":[%s],"nodes":[],"edges":[],"routes":[]}\n' \
  "$ts" "$routers" "$fabric"
exit 0
STUB
chmod +x "$T/bin/curl"

run() {
  rm -f "$T/pw" "$T/restored" "$T/polls" "$T/dash-seen"
  (cd "$T/repo" && env "$@" PATH="$T/bin:/usr/bin:/bin" STUB_DIR="$T" \
    bash demos/46-bgp-fabric-colima/check.sh 2>/dev/null)
}

bad=0
say() { printf '%s\n' "$1"; }

# (0) baseline: signed fabric, key readable, no look-alike → the three rows PASS
out=$(run STUB_MISMATCH=sticky)
for rowpat in 'a wrong password breaks the session' 'kernel has CONFIG_TCP_MD5SIG' 'dashboard sessions agree with vtysh'; do
  printf '%s\n' "$out" | grep -Eq "^  PASS +$rowpat" || {
    say "TEST FAIL: baseline must PASS '$rowpat'"; printf '%s\n' "$out" | grep -E "$rowpat"; bad=1; }
done

# (1) the fabric session is in clear; the cluster's SERVERS sessions are signed
out=$(run STUB_MISMATCH=sticky)
printf '%s\n' "$out" | grep -Eq '^  FAIL +sessions signed on the wire' || {
  say "TEST FAIL: SERVERS md5 packets passed as the fabric session's"
  printf '%s\n' "$out" | grep -E 'signed on the wire'; bad=1; }

# (2) the session comes back with the wrong key still installed
out=$(run STUB_MISMATCH=bounce)
printf '%s\n' "$out" | grep -Eq '^  FAIL +a wrong password breaks the session' || {
  say "TEST FAIL: a session that bounced and returned with the wrong key passed the control"
  printf '%s\n' "$out" | grep -E 'wrong password'; bad=1; }

# (3) fabric/.env has been edited since apply: restore the RUNNING key
out=$(run STUB_MISMATCH=sticky STUB_RUNNING_PW=fabric-real)
printf '%s\n' "$out" | grep -Eq '^  PASS +a wrong password breaks the session' || {
  say "TEST FAIL: the control restored fabric/.env's key, not the running one — the fabric is left down"
  printf '%s\n' "$out" | grep -E 'wrong password'; bad=1; }

# (4) the dashboard agrees on the second sample; vtysh never does
out=$(run STUB_DASH=late STUB_VTYSH_SHORT=1)
printf '%s\n' "$out" | grep -Eq '^  FAIL +dashboard sessions agree with vtysh' || {
  say "TEST FAIL: the re-sample passed the agreement row while vtysh was short of 6/6"
  printf '%s\n' "$out" | grep -E 'agree with vtysh'; bad=1; }

[ "$bad" -eq 0 ] || { say "TEST FAIL: the MD5/agreement rows accept a look-alike"; exit 1; }
say "TEST PASS: SERVERS packets do not prove the fabric session; a bounce-back with the wrong key FAILs; the running key is what gets restored; the agreement retry re-reads vtysh"
exit 0
