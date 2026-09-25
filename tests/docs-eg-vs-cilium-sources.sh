#!/usr/bin/env bash
# test: docs/EG-VS-CILIUM.md does not extend the static-address failure to
# MetalLB, which never had it measured.
#
# The row "`Gateway.spec.addresses` alone" cites EG-PHASE0.md R0.5. R0.5 step 1
# measured `spec.addresses` alone on kube-vip (externalIPs written, arping
# unanswered); step 3 created the MetalLB Gateway "with EnvoyProxy from the
# start" and never tried the address alone. A cell that says "the same" for
# MetalLB is an inference in a document whose last line is "Nothing here is
# estimated". The row must say it was not tried on MetalLB.
#   usage: bash tests/docs-eg-vs-cilium-sources.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
row=$(grep -F '| `Gateway.spec.addresses` alone |' "$R/docs/EG-VS-CILIUM.md")
[ -n "$row" ] || { echo "TEST FAIL: the spec.addresses row is not in docs/EG-VS-CILIUM.md"; exit 1; }
metallb=$(printf '%s' "$row" | awk -F'|' '{print $5}')
if printf '%s' "$metallb" | grep -qi 'the same'; then
  echo "TEST FAIL: the MetalLB cell borrows kube-vip's result: '$metallb'"
  exit 1
fi
printf '%s' "$metallb" | grep -q 'not tried alone' \
  || { echo "TEST FAIL: the MetalLB cell does not say the address was not tried alone: '$metallb'"; exit 1; }
grep -qF 'with its `EnvoyProxy` from the start' "$R/docs/EG-VS-CILIUM.md" \
  || { echo "TEST FAIL: the sources table does not scope R0.5 to kube-vip"; exit 1; }
echo "TEST PASS: the static-address row says MetalLB was not measured alone"
