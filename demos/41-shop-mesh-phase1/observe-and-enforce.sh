#!/usr/bin/env bash
# observe-and-enforce.sh — demo 35's observe-first workflow, on both clusters (R10).
# audit → default-deny → traffic (probe.sh + shopper) → capture → generate → apply under audit →
# verdicts (0 drops of intended paths) → enforce → re-probe.
#
#   demos/41-shop-mesh-phase1/observe-and-enforce.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
HERE=demos/41-shop-mesh-phase1
TRANSCRIPT="$HERE/output/transcript.txt"
mkdir -p "$(dirname "$TRANSCRIPT")"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)

VIP=172.18.255.16
POC1_GW=172.18.255.242
POC2_GW=172.18.255.177

echo "== 1. audit mode Enabled on every shop endpoint in both clusters"
rec "$HERE/audit-both.sh" Enabled || true

echo "== 2. default-deny ingress (so Hubble reports INGRESS as AUDIT, not silence)"
for ctx in "${CTX_ARR[@]}"; do
  rec kubectl --context "$ctx" apply -f "$HERE/20-default-deny-ingress.yaml"
done

echo "== 3. generate traffic: shopper (already looping) + the three doors from the Mac + /healthz /ready /orders"
sleep 8
door() { # host addr path — dump status + X-Served-By; 503 on /ready and /orders is expected
  curl -sk --resolve "$1:443:$2" "https://$1$3" -D - -o /dev/null --connect-timeout 5 --max-time 10 || true
  echo
}
export -f door
for path in / /healthz /ready /orders; do
  rec bash -c 'door "$@"' bash api.shop.poc.local "$VIP" "$path" || true
  rec bash -c 'door "$@"' bash api.poc1.shop.poc.local "$POC1_GW" "$path" || true
  rec bash -c 'door "$@"' bash api.poc2.shop.poc.local "$POC2_GW" "$path" || true
done
unset -f door
# shopper inside each cluster (the in-mesh caller)
for ctx in "${CTX_ARR[@]}"; do
  rec kubectl --context "$ctx" -n shop-clients exec shopper -- sh -c \
    'for p in healthz catalog/items orders/place reviews/latest pay/charge; do wget -qO- --timeout=3 http://api-gateway.shop-edge/$p; echo " $p rc=$?"; done' || true
done
echo "-- wait 30s so every sidecar has made its 5–8s loop under the new policy"
sleep 30

echo "== 4. capture AUDIT flows"
rec "$HERE/flows-both.sh" 400 || true

echo "== 5. one /generate per cluster (cf2cnp on poc1; poc2 copied if it has no observer)"
rec "$HERE/generate-both.sh" || true

echo "== 6. apply generated policies under audit, then verdicts"
for ctx in "${CTX_ARR[@]}"; do
  c=${ctx#kind-}
  f="$HERE/policies/$c/cnp-shop-intent.yaml"
  if [ -f "$f" ]; then
    rec kubectl --context "$ctx" apply -f "$f"
  else
    echo "observe-and-enforce.sh: missing $f" >&2
  fi
done
sleep 10
rec "$HERE/verdicts-both.sh" 200 || true

echo "== 7. enforce (audit mode Disabled) and re-probe the doors"
rec "$HERE/audit-both.sh" Disabled
sleep 5
for ctx in "${CTX_ARR[@]}"; do
  rec kubectl --context "$ctx" -n shop-clients exec shopper -- wget -qO- --timeout=5 http://api-gateway.shop-edge/healthz || true
  echo
done
rec bash -c 'curl -sk --resolve api.shop.poc.local:443:172.18.255.16 https://api.shop.poc.local/healthz -D - -o /dev/null --connect-timeout 5 --max-time 10' || true
rec bash -c 'curl -sk --resolve api.poc1.shop.poc.local:443:172.18.255.242 https://api.poc1.shop.poc.local/healthz -D - -o /dev/null --connect-timeout 5 --max-time 10' || true
rec bash -c 'curl -sk --resolve api.poc2.shop.poc.local:443:172.18.255.177 https://api.poc2.shop.poc.local/healthz -D - -o /dev/null --connect-timeout 5 --max-time 10' || true

echo "== observe-and-enforce.sh done. Read policies/*/cnp-shop-intent.yaml descriptions, then check.sh."
