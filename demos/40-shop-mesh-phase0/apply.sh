#!/usr/bin/env bash
# apply.sh — land demo 40 phase 0 on both clusters: the shared VIP pool, the L2 exclusion, the
# empty doors, the leaf, shopapi:local and both clients. Idempotent. Builds happen here (gotcha
# #118); measurements start in demo 41 after the Docker VM is quiet.
#
#   demos/40-shop-mesh-phase0/apply.sh
#   CONTEXTS="kind-poc1 kind-poc2" demos/40-shop-mesh-phase0/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
TRANSCRIPT=demos/40-shop-mesh-phase0/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")"
: > "$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
VIP_HOME="${VIP_HOME:-kind-poc1}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)

pool_file() {
  case "$1" in
    kind-poc1) echo cilium/lb-ippool-poc1.yaml ;;
    kind-poc2) echo cilium/lb-ippool-poc2.yaml ;;
    *) echo "apply.sh: no pool file for $1" >&2; return 1 ;;
  esac
}
gw_file() {
  case "$1" in
    kind-poc1) echo demos/40-shop-mesh-phase0/30-gateways-poc1.yaml ;;
    kind-poc2) echo demos/40-shop-mesh-phase0/30-gateways-poc2.yaml ;;
    *) echo "apply.sh: no gateway file for $1" >&2; return 1 ;;
  esac
}

echo "== 0. build shopapi:local and shopctl (gotcha #118: builds in this phase, not during measurement)"
rec demos/40-shop-mesh-phase0/shopapi/build.sh
rec demos/40-shop-mesh-phase0/client/go/shopctl/build.sh

echo "== 1. shared VIP pool on every context"
for ctx in "${CTX_ARR[@]}"; do
  rec kubectl --context "$ctx" apply -f cilium/lb-ippool-shared.yaml
done

echo "== 2. L2 policies with the shop-vip-gw exclusion (leases re-evaluate; print before and after)"
for ctx in "${CTX_ARR[@]}"; do
  echo "-- $ctx leases BEFORE"
  rec bash -c "kubectl --context $ctx -n kube-system get leases | grep l2announce || true"
  rec kubectl --context "$ctx" apply -f "$(pool_file "$ctx")"
  echo "-- $ctx leases AFTER"
  rec bash -c "kubectl --context $ctx -n kube-system get leases | grep l2announce || true"
done

echo "== 3. namespace, certificate (Ready ≤ 90s), empty Gateways (Programmed ≤ 120s)"
for ctx in "${CTX_ARR[@]}"; do
  rec kubectl --context "$ctx" apply -f demos/40-shop-mesh-phase0/00-namespaces.yaml
  rec kubectl --context "$ctx" apply -f demos/40-shop-mesh-phase0/20-certificates.yaml
  rec kubectl --context "$ctx" -n shop-edge wait certificate/shop-tls --for=condition=Ready --timeout=90s
  rec kubectl --context "$ctx" apply -f "$(gw_file "$ctx")"
  rec kubectl --context "$ctx" -n shop-edge wait --for=condition=Programmed gateway/shop-gw --timeout=120s
  rec kubectl --context "$ctx" -n shop-edge wait --for=condition=Programmed gateway/shop-vip-gw --timeout=120s
done

echo "== 4. shop-vip-announce on ${VIP_HOME#kind-} only (delete from the other first — never two announcers)"
has_ctx() {
  local want=$1 c
  for c in "${CTX_ARR[@]}"; do
    [ "$c" = "$want" ] && return 0
  done
  return 1
}
if ! has_ctx "$VIP_HOME"; then
  echo "== 4. skipped: $VIP_HOME not in CONTEXTS; run scripts/vip-takeover.sh ${VIP_HOME#kind-} yourself"
else
  for ctx in "${CTX_ARR[@]}"; do
    if [ "$ctx" != "$VIP_HOME" ]; then
      rec kubectl --context "$ctx" delete ciliuml2announcementpolicy shop-vip-announce --ignore-not-found
    fi
  done
  rec kubectl --context "$VIP_HOME" apply -f cilium/l2-shop-vip-announce.yaml
  sleep 3
  rec scripts/vip-takeover.sh --status
fi

echo "== 5. final table: cluster, gateway, address, Programmed, certificate Ready, VIP announced by"
final_table() {
  local lease=cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw
  local poc1_holder poc2_holder announcer=none
  local ctx c cert gw addr prog vip_by

  poc1_holder=$(kubectl --context kind-poc1 -n kube-system get lease "$lease" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
  poc2_holder=$(kubectl --context kind-poc2 -n kube-system get lease "$lease" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
  poc1_holder=${poc1_holder//[[:space:]]/}
  poc2_holder=${poc2_holder//[[:space:]]/}

  if [ -n "$poc1_holder" ] && [ -n "$poc2_holder" ]; then
    announcer=BOTH
  elif [ -n "$poc1_holder" ]; then
    announcer=poc1
  elif [ -n "$poc2_holder" ]; then
    announcer=poc2
  fi

  printf '%-8s %-12s %-16s %-12s %-12s %s\n' \
    CLUSTER GATEWAY ADDRESS PROGRAMMED CERT_READY VIP_BY
  for ctx in "$@"; do
    c=${ctx#kind-}
    cert=$(kubectl --context "$ctx" -n shop-edge get certificate shop-tls \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?')
    for gw in shop-gw shop-vip-gw; do
      addr=$(kubectl --context "$ctx" -n shop-edge get gateway "$gw" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '?')
      prog=$(kubectl --context "$ctx" -n shop-edge get gateway "$gw" \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo '?')
      vip_by=-
      [ "$gw" = shop-vip-gw ] && vip_by=$announcer
      printf '%-8s %-12s %-16s %-12s %-12s %s\n' \
        "$c" "$gw" "${addr:-?}" "${prog:-?}" "${cert:-?}" "$vip_by"
    done
  done
}
export -f final_table
rec bash -c 'final_table "$@"' bash "${CTX_ARR[@]}"
unset -f final_table
