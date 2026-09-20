#!/usr/bin/env bash
# test: frr-agent allow-list without a fabric. Builds frr-agent:local if
# absent, runs it with --network none. /healthz is 200; ;reboot is 404;
# /show/bgp-summary is 502 (vtysh has no daemons).
# usage: bash tests/fabric-agent-allowlist.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$R/scripts/bootstrap/versions-eg.env"
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.7.1}"
if ! docker image inspect frr-agent:local >/dev/null 2>&1; then
  docker build -t frr-agent:local --build-arg FRR_IMAGE="$FRR_IMAGE" \
    -f "$R/demos/46-bgp-fabric/frr-agent/Containerfile" \
    "$R/demos/46-bgp-fabric/frr-agent"
fi
name=frr-agent-allowlist-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --rm -d --network none --name "$name" \
  -e FRR_AGENT_ADDR=127.0.0.1:8080 \
  --entrypoint /usr/local/bin/frr-agent \
  frr-agent:local >/dev/null
ok=0
for _ in $(seq 1 40); do
  if docker exec "$name" python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/healthz")' \
    >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 0.25
done
[ "$ok" -eq 1 ] || { echo "FAIL: /healthz never became 200"; exit 1; }

codes=$(docker exec -i "$name" python3 - <<'PY'
import urllib.error, urllib.request
def code(url):
    try:
        urllib.request.urlopen(url)
        return 200
    except urllib.error.HTTPError as e:
        return e.code
print(code("http://127.0.0.1:8080/healthz"))
print(code("http://127.0.0.1:8080/show/bgp-summary%3Breboot"))
print(code("http://127.0.0.1:8080/show/bgp-summary"))
PY
)
hz=$(printf '%s\n' "$codes" | sed -n '1p')
reboot=$(printf '%s\n' "$codes" | sed -n '2p')
sum=$(printf '%s\n' "$codes" | sed -n '3p')
if [ "$hz" != 200 ] || [ "$reboot" != 404 ] || [ "$sum" != 502 ]; then
  echo "FAIL: healthz=$hz reboot=$reboot summary=$sum (want 200/404/502)"
  exit 1
fi
echo "TEST PASS: frr-agent allow-list — healthz 200, ;reboot 404, vtysh 502"
