#!/usr/bin/env bash
# test: Colima fabric compose parses; no kind overlay files; :colima images;
# dashboard 8098; frr.conf has no secret; .env ignored.
# usage: bash tests/fabric-colima-compose-config.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
FABRIC=$R/demos/46-bgp-fabric-colima/fabric
# shellcheck disable=SC1091
. "$R/scripts/bootstrap/versions-eg.env"
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.7.1}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"
export FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"
export FABRIC_ROUTER_IMAGE="${FABRIC_ROUTER_IMAGE:-frr-agent:colima}"
export FABRIC_DASHBOARD_IMAGE="${FABRIC_DASHBOARD_IMAGE:-bgp-dashboard:colima}"
export FABRIC_COLIMA_DASHBOARD_PORT="${FABRIC_COLIMA_DASHBOARD_PORT:-8098}"

[ ! -f "$FABRIC/compose.lan-eg.yaml" ] \
  || { echo "FAIL: compose.lan-eg.yaml present — Colima demo is fabric-alone this phase"; exit 1; }
[ ! -f "$FABRIC/compose.lan-cilium.yaml" ] \
  || { echo "FAIL: compose.lan-cilium.yaml present — Colima demo is fabric-alone this phase"; exit 1; }

cd "$FABRIC"
# client-side render; does not start a container. --context is omitted on
# purpose: `compose config` talks to no daemon when the files are local.
docker compose -p bgp-fabric-colima-check -f compose.yaml config >/dev/null

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

grep -qxF 'demos/46-bgp-fabric-colima/fabric/.env' "$R/.gitignore" \
  || { echo "FAIL: colima fabric/.env is not ignored"; exit 1; }
[ -f "$FABRIC/.env.example" ] || { echo "FAIL: fabric/.env.example missing"; exit 1; }

cfg=$(docker compose -p bgp-fabric-colima-check -f compose.yaml config)
printf '%s\n' "$cfg" | python3 -c '
import re, sys
cfg = sys.stdin.read()
if "frr-agent:colima" not in cfg:
    print("FAIL: router image default is not frr-agent:colima")
    raise SystemExit(1)
if "bgp-dashboard:colima" not in cfg:
    print("FAIL: dashboard image default is not bgp-dashboard:colima")
    raise SystemExit(1)
if "name: bgp-fabric-colima" not in cfg and "name: bgp-fabric-colima" not in open("compose.yaml").read():
    pass
pubs = re.findall(r"published:\s*\"?(\d+)\"?", cfg)
if pubs != ["8098"]:
    print("FAIL: published ports = %s (want only 8098)" % pubs)
    raise SystemExit(1)
if "host_ip: 127.0.0.1" not in cfg:
    print("FAIL: host_ip 127.0.0.1 missing")
    raise SystemExit(1)
if "gateway: 10.200.200.254" not in open("compose.yaml").read():
    print("FAIL: compose.yaml does not pin mgmt gateway 10.200.200.254")
    raise SystemExit(1)
print("compose dashboard + bind ok")
'
grep -q 'name: bgp-fabric-colima' "$FABRIC/compose.yaml" \
  || { echo "FAIL: compose.yaml name is not bgp-fabric-colima"; exit 1; }

echo "TEST PASS: colima compose parses (no overlays); frr.conf has no literal password; .env ignored; dashboard 127.0.0.1:8098; frr-agent:colima"
exit 0
