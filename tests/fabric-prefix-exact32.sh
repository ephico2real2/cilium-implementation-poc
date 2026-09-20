#!/usr/bin/env bash
# test: VIP prefix-lists are exact /32s; leaves enforce per-cluster blocks
# + as-path (demos 56/57's negative is a wrong-block announcement).
# usage: bash tests/fabric-prefix-exact32.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
bad=0
for leaf in leaf1 leaf2; do
  f=$R/demos/46-bgp-fabric/fabric/frr/$leaf/frr.conf
  for want in \
    'ip prefix-list EG-POC1-VIPS seq 10 permit 10.98.0.0/26 ge 32 le 32' \
    'ip prefix-list EG-POC2-VIPS seq 10 permit 10.98.0.64/26 ge 32 le 32' \
    'ip prefix-list EG-ANYCAST-VIPS seq 10 permit 10.98.0.192/26 ge 32 le 32' \
    'ip prefix-list CILIUM-POC1-VIPS seq 10 permit 10.99.0.0/26 ge 32 le 32' \
    'ip prefix-list CILIUM-POC2-VIPS seq 10 permit 10.99.0.64/26 ge 32 le 32' \
    'ip prefix-list CILIUM-ANYCAST-VIPS seq 10 permit 10.99.0.192/26 ge 32 le 32' \
    'bgp as-path access-list EG-POC1 seq 5 permit ^65021$' \
    'bgp as-path access-list EG-POC2 seq 5 permit ^65022$' \
    'bgp as-path access-list CILIUM-POC1 seq 5 permit ^65001$' \
    'bgp as-path access-list CILIUM-POC2 seq 5 permit ^65002$' \
    'match ip address prefix-list EG-POC1-VIPS' \
    'match as-path EG-POC1' \
    'match ip address prefix-list EG-POC2-VIPS' \
    'match as-path EG-POC2' \
    'match ip address prefix-list EG-ANYCAST-VIPS' \
    'match ip address prefix-list CILIUM-POC1-VIPS' \
    'match as-path CILIUM-POC1' \
    'match ip address prefix-list CILIUM-POC2-VIPS' \
    'match as-path CILIUM-POC2' \
    'match ip address prefix-list CILIUM-ANYCAST-VIPS'
  do
    grep -qF "$want" "$f" || { echo "FAIL: $f lacks '$want'"; bad=1; }
  done
done
for f in "$R"/demos/46-bgp-fabric/fabric/frr/{leaf1,leaf2,spine,edge}/frr.conf; do
  grep -E 'prefix-list EG-VIPS seq 10 permit 10\.98\.0\.0/24 ge 32 le 32' "$f" \
    || { echo "FAIL: $f EG-VIPS not exact /32"; bad=1; }
  grep -E 'prefix-list CILIUM-VIPS seq 10 permit 10\.99\.0\.0/24 ge 32 le 32' "$f" \
    || { echo "FAIL: $f CILIUM-VIPS not exact /32"; bad=1; }
  if grep -E 'prefix-list (EG-VIPS|CILIUM-VIPS) seq 10 permit .* le 32' "$f" \
       | grep -v 'ge 32'; then
    echo "FAIL: $f still admits < /32"; bad=1
  fi
done
[ "$bad" -eq 0 ]
echo "TEST PASS: per-cluster VIP lists and aggregate ge 32 le 32"
