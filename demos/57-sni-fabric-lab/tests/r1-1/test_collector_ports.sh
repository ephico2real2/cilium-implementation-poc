#!/usr/bin/env bash
# Usage: test_collector_ports.sh <collector config> <envoy.yaml>
# Every port the collector listens on must be the target of an Envoy cluster: Envoy is the only
# peer on net-otel, so a port no cluster targets is a listener nothing in the lab can reach.
set -u
listen="$(grep -oE '(endpoint: 0\.0\.0\.0:|port: )[0-9]+' "$1" | grep -oE '[0-9]+$' | sort -u)"
routed="$(grep -oE 'address: otel-collector, port_value: [0-9]+' "$2" | grep -oE '[0-9]+$' | sort -u)"
unrouted="$(comm -23 <(echo "${listen}") <(echo "${routed}") | tr '\n' ' ')"
echo "listening: $(tr '\n' ' ' <<<"${listen}"); routed by Envoy: $(tr '\n' ' ' <<<"${routed}"); unreachable: ${unrouted:-none}"
[ -z "${unrouted}" ]
