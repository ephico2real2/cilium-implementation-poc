#!/usr/bin/env bash
# apply.sh — demo 46: bring the fabric up with the Envoy overlay and record
# the sessions, the routes, and the SERVERS policy. Idempotent.
#   demos/46-bgp-fabric/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
HERE=demos/46-bgp-fabric
FABRIC=$HERE/fabric
PROJECT=bgp-fabric
TRANSCRIPT=$HERE/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '\n### %s — demo 46 apply\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

COMPOSE_ARGS=(-p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml")

echo "== 1. fabric-up.sh eg"
scripts/fabric-up.sh eg

echo "== 2. docker compose ps"
rec docker compose "${COMPOSE_ARGS[@]}" ps

echo "== 3. four show bgp summary"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show bgp summary'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T spine vtysh -c 'show bgp summary'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp summary'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show bgp summary'

echo "== 4. show ip bgp on spine and edge"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T spine vtysh -c 'show ip bgp'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show ip bgp'

echo "== 5. show ip route on edge"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T edge vtysh -c 'show ip route'

echo "== 6. client0 traceroute and ping to leaf1 loopback"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 traceroute -n 10.200.255.11
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 ping -c 3 -W 2 10.200.255.11

echo "== 7. client0 ip route"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T client0 ip route

echo "== 8. leaf1 ping 172.19.0.3 (kind-eg node, on-link)"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 ping -c 1 -W 2 172.19.0.3

echo "== 9. SERVERS group, listen range, prefix-lists, route-maps"
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp peer-group SERVERS'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show bgp listen'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show ip prefix-list'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf1 vtysh -c 'show route-map'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show bgp peer-group SERVERS'
rec docker compose "${COMPOSE_ARGS[@]}" exec -T leaf2 vtysh -c 'show ip prefix-list'

echo "demo 46 apply: recorded"
