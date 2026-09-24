#!/usr/bin/env bash
# test: the leaves' SERVERS peer-group is one the cluster speakers can join.
# GTSM (`ttl-security hops N`) makes the leaf's kernel drop every segment
# with TTL < 255 - N + 1 after accept (bgp_network.c bgp_set_socket_ttl →
# sockopt_minttl). The two speakers demos 56/57 attach send TTL 1:
#   kube-vip v1.2.4 → gobgp v4.9.0 pkg/server/fsm.go:935 `ttl = 1` (no TtlSecurity set in pkg/bgp/peers.go)
#   MetalLB 0.16.0 → frr-k8s v0.0.25 internal/frr/templates/neighborsession.tmpl (no ttl-security line)
# Measured 2026-09-20 on a throwaway fabric: a TTL-1 peer never leaves
# OpenConfirm on the leaf (node side: "Connections established 15; dropped 15");
# with the line removed it is Established in 18 s.
# So: no ttl-security on SERVERS in the committed leaf configs, and no page
# may promise it.
# usage: bash tests/fabric-servers-policy.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
D=$R/demos/55-bgp-fabric-desktop
bad=0
for leaf in leaf1 leaf2; do
  f=$D/fabric/frr/$leaf/frr.conf
  if grep -nE '^[[:space:]]*neighbor SERVERS ttl-security' "$f"; then
    echo "FAIL: $f — SERVERS carries ttl-security; kube-vip (gobgp ttl=1) and frr-k8s (no GTSM) cannot establish"
    bad=1
  fi
  for want in 'neighbor SERVERS remote-as external' 'neighbor SERVERS route-map SERVERS-IN in' \
              'neighbor SERVERS route-map NOTHING out' 'neighbor SERVERS maximum-prefix 64' \
              'neighbor SERVERS timers 3 9' 'bgp listen range 172.19.0.0/17 peer-group SERVERS' \
              'bgp listen range 172.18.0.0/17 peer-group SERVERS'; do
    grep -qF "$want" "$f" || { echo "FAIL: $f lacks '$want'"; bad=1; }
  done
done
for page in "$D/RECAP.md" "$D/NETWORK-TEAM-SHEET.md" "$D/README.md" "$D/GUIDE.md"; do
  if grep -nF 'ttl-security hops 1' "$page"; then
    echo "FAIL: $page still promises ttl-security on SERVERS"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1
echo "TEST PASS: SERVERS has no GTSM; the policy lines and both listen ranges are present; no page promises ttl-security"
exit 0
