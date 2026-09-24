#!/usr/bin/env bash
# test: fabric-up.sh records the poll outcome (A7) — a stub that
# converges on the third poll writes "3 polls" through record.sh.
# usage: bash tests/fabric-up-converge.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# The revision the up-script will compute, so the stub can answer the label
# read with the same value. fabric-up.sh now asks the image which commit it is
# and replaces it when the answer is not the pin; a stub that could not answer
# made the script pull, and a stub that could not pull made this gate fail for
# a reason that has nothing to do with what it measures.
FABRIC_SRC=$("$R/scripts/bgp-fabric-fetch.sh")
IFS=$'\t' read -r WANT_REV _ < <("$FABRIC_SRC/scripts/build-revision.sh")

cat >"$T/bin/docker" <<DOCKER
#!/usr/bin/env bash
case "\$*" in
  *'network ls'*|*'network inspect'*|*'image inspect'*)
    exit 0 ;;
  *'inspect -f'*revision*)
    echo "$WANT_REV"; exit 0 ;;
  *' pull '*|*' tag '*)
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

# /api/state as the dashboard serves it TODAY. The old stub returned the four
# counters alone, which fabric-dashboard-state.py stopped accepting when it
# started counting from the RECORDS instead — {"reachable":1,"routerCount":1,
# "established":6,"sessionCount":6,"sessions":[]} used to pass, which is the
# measurement in that script's own docstring. A stub frozen at an old contract
# fails the script under test for a reason that has nothing to do with it.
# `ts` is generated per call: the checker rejects a snapshot older than four
# polls, and a hardcoded instant is stale the moment it is written.
cat >"$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
  *healthz*) echo ok; exit 0 ;;
  *api/state*)
    now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    cat <<JSON
{"ts":"${now}","poll":"2s",
 "reachable":4,"routerCount":4,"established":6,"sessionCount":6,"external":0,
 "routers":[{"name":"edge","reachable":true,"asn":65000},
            {"name":"spine","reachable":true,"asn":65100},
            {"name":"leaf1","reachable":true,"asn":65101},
            {"name":"leaf2","reachable":true,"asn":65102}],
 "sessions":[{"router":"edge","peer":"10.200.1.18","peerAsn":65100,"state":"Established"},
             {"router":"spine","peer":"10.200.1.19","peerAsn":65000,"state":"Established"},
             {"router":"spine","peer":"10.200.1.2","peerAsn":65101,"state":"Established"},
             {"router":"spine","peer":"10.200.1.10","peerAsn":65102,"state":"Established"},
             {"router":"leaf1","peer":"10.200.1.3","peerAsn":65100,"state":"Established"},
             {"router":"leaf2","peer":"10.200.1.11","peerAsn":65100,"state":"Established"}]}
JSON
    exit 0 ;;
  *) echo "curl-stub: $*" >&2; exit 1 ;;
esac
CURL
chmod +x "$T/bin/curl"

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
