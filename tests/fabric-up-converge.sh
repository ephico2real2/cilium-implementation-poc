#!/usr/bin/env bash
# test: fabric-up.sh records the poll outcome (A7) — a stub that
# converges on the third poll writes "3 polls" through record.sh.
# usage: bash tests/fabric-up-converge.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<DOCKER
#!/usr/bin/env bash
case "\$*" in
  *'network ls'*|*'network inspect'*)
    exit 0 ;;
  *'up -d --wait'*|*'up -d'*)
    exit 0 ;;
  *'show bgp summary json'*)
    n=0
    [ -f "$T/json.count" ] && n=\$(cat "$T/json.count")
    n=\$((n + 1))
    echo "\$n" > "$T/json.count"
    if [ "\$n" -le 2 ]; then
      printf '%s\n' '{"ipv4Unicast":{"peers":{}}}'
      exit 0
    fi
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
  *ping*)
    echo "1 packets transmitted, 1 packets received"; exit 0 ;;
  *'ip route'*)
    echo "default via 10.200.100.2"; exit 0 ;;
  *)
    echo "stub: \$*" >&2; exit 1 ;;
esac
DOCKER
chmod +x "$T/bin/docker"

export PATH="$T/bin:/usr/bin:/bin"
export FABRIC_TRANSCRIPT="$T/transcript.txt"
export FABRIC_PROJECT=bgp-fabric-converge-test
export FABRIC_CONVERGE_SECS=30
mkdir -p "$(dirname "$FABRIC_TRANSCRIPT")"
rc=0
(cd "$R" && bash scripts/fabric-up.sh) >"$T/up.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "TEST FAIL: fabric-up.sh exited $rc"
  cat "$T/up.out"
  exit 1
fi
if ! grep -E 'converged after [0-9]+ s \(3 polls\)' "$T/transcript.txt"; then
  echo "TEST FAIL: transcript has no 'converged after N s (3 polls)' line"
  echo '--- transcript ---'
  cat "$T/transcript.txt"
  exit 1
fi
echo "TEST PASS: fabric-up.sh recorded convergence on the third poll"
