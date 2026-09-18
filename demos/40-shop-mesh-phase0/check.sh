#!/usr/bin/env bash
# check.sh — demo 40 phase 0 PASS/FAIL rows (demo 39's row() style). Exit = FAIL count.
#   demos/40-shop-mesh-phase0/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
fails=0
row() { # ok|fail|warn  what  measured  rule
  local st
  case "$1" in
    ok)   st=PASS ;;
    fail) st=FAIL; fails=$((fails + 1)) ;;
    warn) st=WARN ;;
    *)    st=$1 ;;
  esac
  printf '  %-6s %-70s %-52s %s\n' "$st" "$2" "$3" "$4"
}

VIP=172.18.255.16
POC1_GW=172.18.255.242
POC2_GW=172.18.255.177
LEASE=cilium-l2announce-shop-edge-cilium-gateway-shop-vip-gw
# lease name format, read from a live lease before this demo landed:
#   cilium-l2announce-team-b-cilium-gateway-team-b-gw
#   cilium-l2announce-<namespace>-cilium-gateway-<gateway-name>

printf '\n== demo 40 — the shop platform on the mesh, phase 0 (the ground under it)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# (a) shared pool present in both clusters with the block .16–.31
for ctx in kind-poc1 kind-poc2; do
  start=$(kubectl --context "$ctx" get ciliumloadbalancerippool shared-vip-pool -o jsonpath='{.spec.blocks[0].start}' 2>/dev/null || true)
  stop=$(kubectl --context "$ctx" get ciliumloadbalancerippool shared-vip-pool -o jsonpath='{.spec.blocks[0].stop}' 2>/dev/null || true)
  if [ "$start" = "172.18.255.16" ] && [ "$stop" = "172.18.255.31" ]; then
    row ok "shared-vip-pool on ${ctx#kind-}" "$start–$stop" "block 172.18.255.16–172.18.255.31 in both clusters"
  else
    row fail "shared-vip-pool on ${ctx#kind-}" "start=${start:-?} stop=${stop:-?}" "block 172.18.255.16–172.18.255.31 in both clusters"
  fi
done

# (b) shop-tls Ready in both
for ctx in kind-poc1 kind-poc2; do
  ready=$(kubectl --context "$ctx" -n shop-edge get certificate shop-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "$ready" = True ]; then
    row ok "shop-tls Ready on ${ctx#kind-}" "Ready=$ready" "Certificate shop-tls Ready=True"
  else
    row fail "shop-tls Ready on ${ctx#kind-}" "Ready=${ready:-?}" "Certificate shop-tls Ready=True"
  fi
done

# (c) 4 Gateways Programmed with the expected addresses
expect_gw() { # ctx name want_addr
  local ctx=$1 name=$2 want=$3
  local addr prog extra
  addr=$(kubectl --context "$ctx" -n shop-edge get gateway "$name" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  prog=$(kubectl --context "$ctx" -n shop-edge get gateway "$name" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  extra=$(kubectl --context "$ctx" -n shop-edge get gateway "$name" -o jsonpath='{.status.addresses[*].value}' 2>/dev/null || true)
  if [ "$prog" = True ] && [ "$addr" = "$want" ]; then
    row ok "${ctx#kind-}/$name Programmed at $want" "addr=$addr Programmed=$prog (${extra})" "Programmed=True and status.addresses[0]=$want"
  else
    row fail "${ctx#kind-}/$name Programmed at $want" "addr=${addr:-?} Programmed=${prog:-?} (${extra:-?})" "Programmed=True and status.addresses[0]=$want"
  fi
}
expect_gw kind-poc1 shop-gw "$POC1_GW"
expect_gw kind-poc1 shop-vip-gw "$VIP"
expect_gw kind-poc2 shop-gw "$POC2_GW"
expect_gw kind-poc2 shop-vip-gw "$VIP"

# (d) exactly ONE cluster holds an l2announce lease for the VIP's Service
poc1_holder=$(kubectl --context kind-poc1 -n kube-system get lease "$LEASE" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
poc2_holder=$(kubectl --context kind-poc2 -n kube-system get lease "$LEASE" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
n1=0; n2=0
[ -n "$poc1_holder" ] && n1=1
[ -n "$poc2_holder" ] && n2=1
if [ $((n1 + n2)) -eq 1 ]; then
  if [ "$n1" -eq 1 ]; then
    row ok "exactly one cluster holds the VIP l2announce lease" "poc1 holder=$poc1_holder" "lease $LEASE has a holderIdentity in one context, none in the other"
  else
    row ok "exactly one cluster holds the VIP l2announce lease" "poc2 holder=$poc2_holder" "lease $LEASE has a holderIdentity in one context, none in the other"
  fi
else
  row fail "exactly one cluster holds the VIP l2announce lease" "poc1 holder=${poc1_holder:-absent} poc2 holder=${poc2_holder:-absent}" "a non-empty holderIdentity in exactly one context (a name with no holder is a dying lease)"
fi

# (e) VIP door from the Mac: 404 (phase 0, no routes) or 200 (routes attached —
# demo 41) is a PASS; 000 or any other code is a FAIL. Leaf issuer is the shared root.
http_code() { # host addr — return 000 on curl failure, never concatenate the fallback onto a printed code
  local host=$1 addr=$2 code
  if ! code=$(curl -sk --resolve "$host:443:$addr" "https://$host/" \
      -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 2>/dev/null); then
    printf '000'
    return
  fi
  printf '%s' "$code"
}

door_measured() { # code — MEASURED column: the code and which phase it implies
  case "$1" in
    404) printf 'http_code=%s (phase 0, no routes)' "$1" ;;
    200) printf 'http_code=%s (routes attached — demo 41)' "$1" ;;
    *)   printf 'http_code=%s' "${1:-000}" ;;
  esac
}

vip_code=$(http_code api.shop.poc.local "$VIP")
if [ "$vip_code" = "404" ] || [ "$vip_code" = "200" ]; then
  row ok "VIP https://api.shop.poc.local @ $VIP answers" \
    "$(door_measured "$vip_code")" \
    "http_code=404 (no routes yet) or 200 (routes attached — demo 41)"
else
  row fail "VIP https://api.shop.poc.local @ $VIP answers" \
    "http_code=${vip_code:-000}" \
    "http_code=404 (no routes yet) or 200 (routes attached — demo 41); 000 or anything else is FAIL"
fi

vip_issuer=$(echo | openssl s_client -servername api.shop.poc.local \
  -connect "${VIP}:443" 2>/dev/null |
  openssl x509 -noout -issuer 2>/dev/null || true)
if echo "$vip_issuer" | grep -q clustermesh-root-ca; then
  row ok "VIP leaf issuer is clustermesh-root-ca" "$vip_issuer" \
    "openssl x509 -noout -issuer contains clustermesh-root-ca"
else
  row fail "VIP leaf issuer is clustermesh-root-ca" \
    "${vip_issuer:-no certificate}" \
    "openssl x509 -noout -issuer contains clustermesh-root-ca"
fi

# (f) per-cluster doors the same way
door() { # host addr
  local host=$1 addr=$2 code issuer
  code=$(http_code "$host" "$addr")
  if [ "$code" = "404" ] || [ "$code" = "200" ]; then
    row ok "https://$host @ $addr answers" "$(door_measured "$code")" \
      "http_code=404 (no routes yet) or 200 (routes attached — demo 41)"
  else
    row fail "https://$host @ $addr answers" "${code:-000}" \
      "http_code=404 (no routes yet) or 200 (routes attached — demo 41); 000 or anything else is FAIL"
  fi

  issuer=$(echo | openssl s_client -servername "$host" \
    -connect "${addr}:443" 2>/dev/null |
    openssl x509 -noout -issuer 2>/dev/null || true)
  if echo "$issuer" | grep -q clustermesh-root-ca; then
    row ok "$host leaf issuer is clustermesh-root-ca" "$issuer" \
      "same root as the VIP"
  else
    row fail "$host leaf issuer is clustermesh-root-ca" \
      "${issuer:-no certificate}" "same root as the VIP"
  fi
}
door api.poc1.shop.poc.local "$POC1_GW"
door api.poc2.shop.poc.local "$POC2_GW"

# (g) shopapi:local on all four nodes; both clients run --help
# Fixed list: `kind get nodes` failing used to silently drop these four rows.
nodes=(
  poc1-control-plane
  poc1-worker
  poc2-control-plane
  poc2-worker
)
for node in "${nodes[@]}"; do
  imgs=$(docker exec "$node" crictl images 2>/dev/null || true)
  if printf '%s\n' "$imgs" | grep -q shopapi; then
    row ok "shopapi:local on $node" \
      "crictl images | grep shopapi matched" \
      "docker exec $node crictl images contains shopapi"
  else
    row fail "shopapi:local on $node" "not found" \
      "docker exec $node crictl images contains shopapi"
  fi
done

go_bin=demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-darwin-arm64
[ "$(uname -s)" != Darwin ] && go_bin=demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-linux-amd64
if [ -x "$go_bin" ] && "$go_bin" --help >/dev/null 2>&1; then
  row ok "shopctl (Go) --help" "$go_bin" "the darwin-arm64 / linux-amd64 binary runs --help"
else
  row fail "shopctl (Go) --help" "${go_bin} missing or --help failed" "build.sh writes bin/shopctl-*"
fi
py=demos/40-shop-mesh-phase0/client/python/shopctl.py
if python3 "$py" --help >/dev/null 2>&1; then
  row ok "shopctl.py --help" "$py" "the Python client runs --help"
else
  row fail "shopctl.py --help" "--help failed" "python3 shopctl.py --help"
fi

exit "$fails"
