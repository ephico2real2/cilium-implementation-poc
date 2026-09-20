#!/usr/bin/env bash
# test: demo 46 check.sh contract (PATH-stub).
#   (a) a dead docker produces FAIL rows (never PASS) and exit ≠ 0
#   (b) a vtysh stub printing Active/Connect instead of Established → FAIL
#   (c) no `|| echo 000` in apply.sh, check.sh, or fabric-*.sh
# usage: bash tests/check46-contract.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$R/demos/46-bgp-fabric/check.sh
APPLY=$R/demos/46-bgp-fabric/apply.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/demos/46-bgp-fabric" "$T/repo/scripts"
cp "$CHECK" "$T/repo/demos/46-bgp-fabric/check.sh"
cp "$APPLY" "$T/repo/demos/46-bgp-fabric/apply.sh"
cp "$R/scripts/fabric-bgp-summary.py" "$T/repo/scripts/fabric-bgp-summary.py"
# check.sh cds to repo root and reads fabric/compose.yaml paths; dummy files
mkdir -p "$T/repo/demos/46-bgp-fabric/fabric"
printf 'name: bgp-fabric\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.yaml"
printf 'name: overlay\n' > "$T/repo/demos/46-bgp-fabric/fabric/compose.lan-eg.yaml"

# (a) dead docker
printf '#!/usr/bin/env bash\necho "Cannot connect to the Docker daemon" >&2; exit 1\n' > "$T/bin/docker"
chmod +x "$T/bin/docker"

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/46-bgp-fabric/check.sh 2>/dev/null) || rc=$?
rc=${rc:-0}

if printf '%s\n' "$out" | grep -qE '^  PASS'; then
  echo "TEST FAIL: a dead docker produced a PASS row"
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$out" | grep -qE '^  FAIL' \
  || { echo "TEST FAIL: dead docker — no FAIL rows"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: dead docker — check.sh exited 0"; exit 1; }

# (b) vtysh prints Active/Connect — sessions must FAIL (never substring-PASS)
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Minimal compose/exec stub: containers look up, vtysh is not Established.
case "$*" in
  *'ps --format'*)
    echo "bgp-fabric-edge-1 running"
    echo "bgp-fabric-spine-1 running"
    echo "bgp-fabric-leaf1-1 running"
    echo "bgp-fabric-leaf2-1 running"
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

out=$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" bash demos/46-bgp-fabric/check.sh 2>/dev/null) || rc=$?
rc=${rc:-0}
if printf '%s\n' "$out" | grep -Eq 'PASS[[:space:]]+six fabric sessions'; then
  echo "TEST FAIL: Active/Connect was accepted as Established"
  printf '%s\n' "$out" | grep 'six fabric'
  exit 1
fi
printf '%s\n' "$out" | grep -Eq 'FAIL[[:space:]]+six fabric sessions' \
  || { echo "TEST FAIL: no FAIL row for Active/Connect sessions"; printf '%s\n' "$out"; exit 1; }
[ "$rc" -ne 0 ] \
  || { echo "TEST FAIL: Active/Connect — check.sh exited 0"; exit 1; }

# (c) no || echo 000
if grep -nF '|| echo 000' "$APPLY" "$CHECK" \
     "$R/scripts/fabric-up.sh" "$R/scripts/fabric-down.sh" \
     "$R/scripts/fabric-status.sh" "$R/scripts/fabric-vm-route.sh"; then
  echo "TEST FAIL: fabric scripts still carry || echo 000"
  exit 1
fi

echo "TEST PASS: dead docker → FAIL (never PASS, exit ≠ 0); Active/Connect is FAIL; no || echo 000"
exit 0
