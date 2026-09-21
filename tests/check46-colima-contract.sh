#!/usr/bin/env bash
# test: demo 46-colima check.sh contract (PATH-stub).
#   (a) a dead docker produces no PASS row and exit ≠ 0
#   (b) a vtysh stub printing Active/Connect instead of Established → FAIL
#   (c) no `|| echo 000` in the Colima apply/check/fabric-colima scripts
#   (d) ping rc=0 without "1 received" must FAIL loopbacks
#   (e) empty running-config rc=0 must FAIL RFC 8212
# usage: bash tests/check46-colima-contract.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$R/demos/46-bgp-fabric-colima/check.sh
APPLY=$R/demos/46-bgp-fabric-colima/apply.sh
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/46-bgp-fabric-colima/fabric" "$T/repo/scripts"
cp "$CHECK" "$T/repo/demos/46-bgp-fabric-colima/check.sh"
cp "$APPLY" "$T/repo/demos/46-bgp-fabric-colima/apply.sh"
cp "$R/scripts/fabric-bgp-summary.py" "$T/repo/scripts/fabric-bgp-summary.py"
cp "$R/scripts/fabric-colima-lib.sh" "$T/repo/scripts/fabric-colima-lib.sh"
mkdir -p "$T/repo/scripts/bootstrap"
cp "$R/scripts/bootstrap/versions-eg.env" "$T/repo/scripts/bootstrap/versions-eg.env"
printf 'name: bgp-fabric-colima\n' > "$T/repo/demos/46-bgp-fabric-colima/fabric/compose.yaml"

# (a) dead docker — inspect/info fail; refuse, never PASS
printf '#!/usr/bin/env bash\necho "Cannot connect to the Docker daemon" >&2; exit 1\n' > "$T/bin/docker"
chmod +x "$T/bin/docker"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/colima"
chmod +x "$T/bin/colima"

rc=0
out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/46-bgp-fabric-colima/check.sh 2>/dev/null
) || rc=$?
if printf '%s\n' "$out" | grep -qE '^  PASS'; then
  echo "TEST FAIL: a dead docker produced a PASS row"
  printf '%s\n' "$out"
  exit 1
fi
[ "$rc" -ne 0 ] || { echo "TEST FAIL: dead docker — check.sh exited 0"; exit 1; }

# (b) vtysh prints Active/Connect
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'context inspect'*) echo '{}'; exit 0 ;;
  *' info'*) echo ok; exit 0 ;;
  *'ps --format'*)
    echo "bgp-fabric-colima-edge-1 running"
    echo "bgp-fabric-colima-spine-1 running"
    echo "bgp-fabric-colima-leaf1-1 running"
    echo "bgp-fabric-colima-leaf2-1 running"
    exit 0
    ;;
  *'show bgp summary json'*)
    cat <<'JSON'
{"ipv4Unicast":{"peers":{
  "10.200.1.18":{"state":"Active","remoteAs":65100},
  "10.200.1.2":{"state":"Connect","remoteAs":65101},
  "10.200.1.10":{"state":"Active","remoteAs":65102},
  "10.200.1.19":{"state":"Connect","remoteAs":65000},
  "10.200.1.3":{"state":"Active","remoteAs":65100},
  "10.200.1.11":{"state":"Connect","remoteAs":65100}
}}}
JSON
    exit 0
    ;;
  *ping*) echo "ping: failed"; exit 1 ;;
  *) echo "stub: $*"; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"

rc=0
out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/46-bgp-fabric-colima/check.sh 2>/dev/null
) || rc=$?
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+six fabric sessions'; then
  echo "TEST FAIL: Active/Connect was accepted as Established"
  printf '%s\n' "$out" | grep 'six fabric'
  exit 1
fi
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+six fabric sessions' \
  || { echo "TEST FAIL: no FAIL row for Active/Connect sessions"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] || { echo "TEST FAIL: Active/Connect — check.sh exited 0"; exit 1; }

# (c) no || echo 000
if grep -nF '|| echo 000' "$APPLY" "$CHECK" \
     "$R/scripts/fabric-colima-up.sh" "$R/scripts/fabric-colima-down.sh" \
     "$R/scripts/fabric-colima-status.sh" "$R/scripts/fabric-colima-lib.sh"; then
  echo "TEST FAIL: colima fabric scripts still carry || echo 000"
  exit 1
fi

# (d)(e) ping without 1 received; empty running-config
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *'context inspect'*) echo '{}'; exit 0 ;;
  *' info'*) echo ok; exit 0 ;;
  *'ps --format'*)
    echo "bgp-fabric-colima-edge-1 running"
    echo "bgp-fabric-colima-spine-1 running"
    echo "bgp-fabric-colima-leaf1-1 running"
    echo "bgp-fabric-colima-leaf2-1 running"; exit 0 ;;
  *'ps -q'*) echo "cid"; exit 0 ;;
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
  *ping*) echo "ping: failed"; exit 0 ;;
  *'show running-config'*) echo ""; exit 0 ;;
  *'show ip route'*) echo "10.200.100.0/24 via 10.200.1.3"; exit 0 ;;
  *) echo "stub: $*"; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"
rc=0
out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/46-bgp-fabric-colima/check.sh 2>/dev/null
) || rc=$?
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+client0 ping' \
  || { echo "TEST FAIL: ping rc=0 without 1 received was PASS"; exit 1; }
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+RFC 8212' \
  || { echo "TEST FAIL: empty running-config was RFC PASS"; exit 1; }

echo "TEST PASS: dead docker → no PASS (exit ≠ 0); Active/Connect is FAIL; no || echo 000; ping without 1 received is FAIL; empty running-config is RFC FAIL"
exit 0
