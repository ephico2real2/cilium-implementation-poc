#!/usr/bin/env bash
# test: demo 46 check.sh must not PASS on a look-alike (PATH-stub docker).
#   (d) `frr defaults datacenter` (RFC 8212 OFF, nothing printed in the
#       running-config — bgp_vty.c FRR_CFG_DEFAULT_BOOL(BGP_EBGP_REQUIRES_POLICY))
#       → the "RFC 8212 in effect" row is FAIL
#   (e) `seq 10 deny …` → the per-cluster / EG-VIPS prefix-list row is FAIL
#   (f) leaf logs carrying "Unable to set TCP MD5 option" → a WARN row that names
#       TCP_MD5SIG; clean logs → PASS; unreadable logs → FAIL
#   listen stub: only 172.19.0.0/17 → the listen row is FAIL
# usage: bash tests/check46-false-pass.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/46-bgp-fabric/fabric" "$T/repo/scripts"
cp "$R/demos/46-bgp-fabric/check.sh" "$T/repo/demos/46-bgp-fabric/check.sh"
cp "$R/scripts/fabric-bgp-summary.py" "$T/repo/scripts/fabric-bgp-summary.py"
printf 'name: bgp-fabric\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.yaml"
printf 'name: overlay\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.lan-eg.yaml"

# A healthy fabric, with knobs: STUB_PROFILE, STUB_PL_ACTION, STUB_LOGS, STUB_LISTEN
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
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
  *ping*) echo "1 packets transmitted, 1 packets received"; exit 0 ;;
  inspect*) case "$*" in *cid-leaf1) echo 172.19.254.11;; *cid-leaf2) echo 172.19.254.12;; esac; exit 0 ;;
  *) echo "stub: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"
run() { (cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/46-bgp-fabric/check.sh 2>/dev/null); }

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

echo "TEST PASS: datacenter profile → FAIL; deny entry → FAIL; TCP_MD5SIG refused → WARN, clean → PASS, unreadable → FAIL; one listen range → FAIL"
exit 0
