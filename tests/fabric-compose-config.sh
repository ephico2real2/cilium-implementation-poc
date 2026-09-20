#!/usr/bin/env bash
# test: fabric compose files parse; committed leaf frr.conf has no secret.
# usage: bash tests/fabric-compose-config.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
FABRIC=$R/demos/46-bgp-fabric/fabric
# shellcheck disable=SC1091
. "$R/scripts/bootstrap/versions-eg.env"
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.5.3}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"
export FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"

cd "$FABRIC"
docker compose -p bgp-fabric-check -f compose.yaml config >/dev/null
docker compose -p bgp-fabric-check -f compose.yaml -f compose.lan-eg.yaml config >/dev/null
docker compose -p bgp-fabric-check -f compose.yaml -f compose.lan-cilium.yaml config >/dev/null
docker compose -p bgp-fabric-check -f compose.yaml -f compose.lan-eg.yaml -f compose.lan-cilium.yaml config >/dev/null

bad=0
for f in frr/leaf1/frr.conf frr/leaf2/frr.conf frr/edge/frr.conf frr/spine/frr.conf; do
  if grep -F -q 'lab-bgp' "$f"; then
    echo "FAIL: $f contains literal lab-bgp"
    bad=1
  fi
  if ! awk '
    $1 == "neighbor" && $3 == "password" {
      seen = 1
      if (NF != 4 || $4 != "${FABRIC_BGP_PASSWORD}")
        bad = 1
    }
    END { exit (bad || !seen) }
  ' "$f"; then
    echo "FAIL: $f has missing or non-placeholder neighbor passwords"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1

grep -qxF 'demos/46-bgp-fabric/fabric/.env' "$R/.gitignore" || { echo "FAIL: fabric/.env is not ignored"; exit 1; }
[ -f "$FABRIC/.env.example" ] || { echo "FAIL: fabric/.env.example missing"; exit 1; }
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
cp -R "$FABRIC"/. "$tmp/"; rm -f "$tmp/.env"
( cd "$tmp" && docker compose -p bgp-fabric-check -f compose.yaml config >/dev/null ) || { echo "FAIL: compose needs .env to exist"; exit 1; }

# a dollar-prefixed literal must not escape the password check
other=$tmp/other.conf
cp "$FABRIC/frr/leaf1/frr.conf" "$other"
python3 - "$other" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("${FABRIC_BGP_PASSWORD}", "$OTHER"))
PY
if awk '
  $1 == "neighbor" && $3 == "password" {
    seen = 1
    if (NF != 4 || $4 != "${FABRIC_BGP_PASSWORD}")
      bad = 1
  }
  END { exit (bad || !seen) }
' "$other"; then
  echo "FAIL: password check certified \$OTHER"
  exit 1
fi

echo "TEST PASS: compose config parses (base, eg, cilium, both); frr.conf has no literal password; .env optional; \$OTHER rejected"
exit 0
