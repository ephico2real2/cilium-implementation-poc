#!/usr/bin/env bash
# test: an agent answers the management LAN and nothing else. The FORWARD
# drop in fabric/entrypoint.sh stops transit onto 10.200.200.0/24, but a
# packet addressed to a router's OWN management IP arrives on a data-plane
# interface and is delivered locally, so it never reaches FORWARD. Measured
# 2026-09-20 before the INPUT rules: client0 read
# http://10.200.200.1:8080/show/bgp-summary (200, the edge's whole table)
# while 10.200.200.{2,11,12} timed out.
#   usage: bash tests/fabric-agent-mgmt-input.sh   (the fabric must be up)
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
# Either fabric: demo 55 on a plain engine by default, demo 46 on Colima when
# the caller passes its values. Hardcoding one of them made this gate probe a
# fabric that was not running and report rc=1 — "the probe itself failed",
# which its own comment says proves nothing.
PROJECT="${FABRIC_PROJECT:-bgp-fabric}"
FABRIC_DEMO_HERE="${FABRIC_DEMO_HERE:-demos/55-bgp-fabric-desktop}"
DOCKER_CTX="${CTX_DOCKER-}"
DOCKER_CTX_ARGS=()
[ -n "$DOCKER_CTX" ] && DOCKER_CTX_ARGS=(--context "$DOCKER_CTX")
COMPOSE=(docker "${DOCKER_CTX_ARGS[@]}" compose -p "$PROJECT" -f "$R/$FABRIC_DEMO_HERE/fabric/compose.yaml")
fails=0
for addr in 10.200.200.1 10.200.200.2 10.200.200.11 10.200.200.12; do
  rc=0
  "${COMPOSE[@]}" exec -T client0 curl --max-time 3 -s -o /dev/null \
    "http://$addr:8080/show/bgp-summary" >/dev/null 2>&1 || rc=$?
  # 7 = refused, 28 = timed out. Any other code means the probe itself
  # failed (no container, no curl) and proves nothing.
  if [ "$rc" -eq 7 ] || [ "$rc" -eq 28 ]; then
    echo "ok: client0 cannot reach $addr (curl rc=$rc)"
  else
    echo "FAIL: client0 (data plane) reached the agent on $addr (curl rc=$rc)"
    fails=$((fails + 1))
  fi
done
for addr in 10.200.200.1 10.200.200.2 10.200.200.11 10.200.200.12; do
  rc=0
  "${COMPOSE[@]}" exec -T dashboard wget -q -T 5 -O /dev/null \
    "http://$addr:8080/show/bgp-summary" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: the dashboard lost the agent on $addr (wget rc=$rc)"
    fails=$((fails + 1))
  else
    echo "ok: dashboard reads $addr"
  fi
done
if [ "$fails" -ne 0 ]; then
  echo "TEST FAIL: $fails"
  exit 1
fi
echo "TEST PASS: the agents answer the management LAN only; the data plane cannot read them"
