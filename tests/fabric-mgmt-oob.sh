#!/usr/bin/env bash
# test: out-of-band management LAN — compose has mgmt with the five
# addresses; no frr.conf leaks 10.200.200; dashboard is not on wan and
# has no cap_add; every FRR_AGENT_ADDR is on 10.200.200.0/24.
# usage: bash tests/fabric-mgmt-oob.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
FABRIC=$R/demos/55-bgp-fabric-desktop/fabric
# shellcheck disable=SC1091
. "$R/scripts/bootstrap/versions-eg.env"
export FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.7.1}"
export NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"
export FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"
export FABRIC_ROUTER_IMAGE="${FABRIC_ROUTER_IMAGE:-frr-agent:local}"
export FABRIC_DASHBOARD_IMAGE="${FABRIC_DASHBOARD_IMAGE:-bgp-dashboard:local}"

cd "$FABRIC"
cfg=$(docker compose -p bgp-fabric-check -f compose.yaml config)
printf '%s\n' "$cfg" | python3 -c '
import ipaddress, re, sys
cfg = sys.stdin.read()
want = {
    "edge": "10.200.200.1",
    "spine": "10.200.200.2",
    "leaf1": "10.200.200.11",
    "leaf2": "10.200.200.12",
    "dashboard": "10.200.200.100",
}
if "mgmt:" not in cfg:
    print("FAIL: compose config has no mgmt network")
    raise SystemExit(1)
if "10.200.200.0/24" not in cfg:
    print("FAIL: mgmt subnet is not 10.200.200.0/24")
    raise SystemExit(1)
if "gateway: 10.200.200.254" not in cfg:
    print("FAIL: mgmt gateway must be pinned to .254 (Docker would take .1, the edge)")
    raise SystemExit(1)
missing = [n for n, a in want.items() if a not in cfg]
if missing:
    print("FAIL: mgmt addresses missing for %s" % ",".join(missing))
    raise SystemExit(1)
# dashboard: no wan attachment, no cap_add (NET_ADMIN would be the wan trick)
dash = re.search(r"(?ms)^  dashboard:.*?(?=^  [a-z]|\Z)", cfg)
if not dash:
    # compose config may indent services under "services:"
    dash = re.search(r"(?ms)^    dashboard:.*?(?=^    [a-z]|\Z)", cfg)
if not dash:
    print("FAIL: dashboard service block not found")
    raise SystemExit(1)
block = dash.group(0)
if re.search(r"(?m)^\s+wan:", block):
    print("FAIL: dashboard is still on wan")
    raise SystemExit(1)
if "cap_add" in block:
    print("FAIL: dashboard has cap_add")
    raise SystemExit(1)
net = ipaddress.ip_network("10.200.200.0/24")
addrs = re.findall(r"FRR_AGENT_ADDR:\s*(\S+)", cfg)
if len(addrs) < 4:
    print("FAIL: expected 4 FRR_AGENT_ADDR, got %s" % addrs)
    raise SystemExit(1)
for raw in addrs:
    host = raw.split(":")[0]
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        print("FAIL: FRR_AGENT_ADDR not an IP: %s" % raw)
        raise SystemExit(1)
    if ip not in net:
        print("FAIL: FRR_AGENT_ADDR %s is not in 10.200.200.0/24" % raw)
        raise SystemExit(1)
print("compose mgmt + dashboard oob ok")
'

bad=0
for f in frr/edge/frr.conf frr/spine/frr.conf frr/leaf1/frr.conf frr/leaf2/frr.conf; do
  if grep -Eiq 'redistribute|network 10\.200\.200' "$f"; then
    echo "FAIL: $f leaks mgmt (redistribute or network 10.200.200)"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1
if ! grep -q 'FORWARD' "$FABRIC/entrypoint.sh" || ! grep -q '10.200.200.0/24' "$FABRIC/entrypoint.sh"; then
  echo "FAIL: entrypoint does not drop FORWARD onto mgmt"
  exit 1
fi

echo "TEST PASS: mgmt 10.200.200.0/24 with five addresses; no frr.conf redistribute/network 10.200.200; dashboard off wan and without cap_add; FRR_AGENT_ADDR on mgmt"
exit 0
