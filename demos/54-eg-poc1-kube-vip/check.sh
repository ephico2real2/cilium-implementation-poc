#!/usr/bin/env bash
# check.sh — demo 54 PASS/FAIL rows (demo 51's row() style). Exit = FAIL count.
# At most 15 rows. A failed kubectl is a FAIL, never a PASS.
#   demos/54-eg-poc1-kube-vip/check.sh
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

CTX=kind-eg-poc1
CA=.tmp/eg-poc1-root-ca.crt
KV_CLASS=kube-vip.io/kube-vip-class
HTTP_ADDR=172.19.255.100
GRPC_ADDR=172.19.255.101
HTTP_HOST=api.eg-poc1.poc.local
GRPC_HOST=grpc.eg-poc1.poc.local

printf '\n== demo 54 — one cluster, kube-vip, two Gateways (HTTP isolated from gRPC)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# 1. kube-vip DS ready
ds_out=$(kubectl --context "$CTX" -n kube-system get ds kube-vip-ds \
  -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>&1)
ds_rc=$?
if [ "$ds_rc" -ne 0 ]; then
  row fail "kube-vip DS ready" "kubectl failed: $(printf '%s' "$ds_out" | tr '\n' ' ' | head -c 60)" "R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)"
elif [ -n "$ds_out" ] && [ "${ds_out#*/}" != "0" ] && [ "${ds_out%%/*}" = "${ds_out#*/}" ]; then
  row ok "kube-vip DS ready" "ready=$ds_out" "R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)"
else
  row fail "kube-vip DS ready" "ready=${ds_out:-absent}" "R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)"
fi

# 2. cloud-provider Available
cp_out=$(kubectl --context "$CTX" -n kube-system get deploy kube-vip-cloud-provider \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>&1)
cp_rc=$?
if [ "$cp_rc" -ne 0 ]; then
  row fail "kube-vip-cloud-provider Available" "kubectl failed: $(printf '%s' "$cp_out" | tr '\n' ' ' | head -c 60)" "R4 — cloud-provider v0.0.12 Available"
elif [ "$cp_out" = True ]; then
  row ok "kube-vip-cloud-provider Available" "Available=$cp_out" "R4 — cloud-provider v0.0.12 Available"
else
  row fail "kube-vip-cloud-provider Available" "Available=${cp_out:-?}" "R4 — cloud-provider v0.0.12 Available"
fi

# 3–4. Gateways Programmed at the pinned address with Service ingress
expect_gw() { # name want_addr
  local name=$1 want=$2 addr prog svc_ingress gw_err svc_err

  gw_err=$(kubectl --context "$CTX" -n shop get gateway "$name" \
    -o jsonpath='{.status.addresses[0].value}{"|"}{.status.conditions[?(@.type=="Programmed")].status}' 2>&1)
  if [ $? -ne 0 ]; then
    row fail "$name Programmed at $want" "kubectl failed: $(printf '%s' "$gw_err" | tr '\n' ' ' | head -c 60)" \
      "R4 / R8 — Gateway address and Service ingress must both be $want"
    return
  fi
  addr=${gw_err%%|*}
  prog=${gw_err#*|}

  svc_err=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$name" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>&1)
  if [ $? -ne 0 ]; then
    row fail "$name Programmed at $want" "kubectl svc failed: $(printf '%s' "$svc_err" | tr '\n' ' ' | head -c 60)" \
      "R4 / R8 — Gateway address and Service ingress must both be $want"
    return
  fi
  svc_ingress=$svc_err

  if [ "$prog" = True ] && [ "$addr" = "$want" ] && [ "$svc_ingress" = "$want" ]; then
    row ok "$name Programmed at $want" \
      "addr=$addr svcIngress=$svc_ingress Programmed=$prog" \
      "R4 / R8 — Gateway address and Service ingress both equal $want"
  else
    row fail "$name Programmed at $want" \
      "addr=${addr:-?} svcIngress=${svc_ingress:-?} Programmed=${prog:-?}" \
      "R4 / R8 — Gateway address and Service ingress both equal $want"
  fi
}
expect_gw http-gw "$HTTP_ADDR"
expect_gw grpc-gw "$GRPC_ADDR"

# 5. both Envoy Services carry the class
class_http=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
  -l "gateway.envoyproxy.io/owning-gateway-name=http-gw" \
  -o jsonpath='{.items[0].spec.loadBalancerClass}' 2>&1)
class_http_rc=$?
class_grpc=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
  -l "gateway.envoyproxy.io/owning-gateway-name=grpc-gw" \
  -o jsonpath='{.items[0].spec.loadBalancerClass}' 2>&1)
class_grpc_rc=$?
if [ "$class_http_rc" -ne 0 ] || [ "$class_grpc_rc" -ne 0 ]; then
  row fail "both Envoy Services carry the class" \
    "kubectl failed http_rc=$class_http_rc grpc_rc=$class_grpc_rc" \
    "D11 — EnvoyProxy names kube-vip.io/kube-vip-class on both doors"
elif [ "$class_http" = "$KV_CLASS" ] && [ "$class_grpc" = "$KV_CLASS" ]; then
  row ok "both Envoy Services carry the class" "http=$class_http grpc=$class_grpc" \
    "D11 — EnvoyProxy names kube-vip.io/kube-vip-class on both doors"
else
  row fail "both Envoy Services carry the class" "http=${class_http:-?} grpc=${class_grpc:-?}" \
    "D11 — EnvoyProxy names kube-vip.io/kube-vip-class on both doors"
fi

# 6–7. ARP one responder 3/3, every probe a broadcast
arping_check() { # ip label
  local ip=$1 label=$2 out n macs
  out=$(docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -b -c 3 -I eth0 "$ip" 2>&1 || true)
  n=$(printf '%s\n' "$out" | grep -c 'Unicast reply' || true)
  macs=$(printf '%s\n' "$out" | awk '/Unicast reply/{gsub(/[\[\]]/,"",$5); print $5}' | sort -u | wc -l | tr -d ' ')
  if [ "$n" -eq 3 ] && [ "$macs" -eq 1 ]; then
    row ok "ARP $label $ip one responder 3/3" "replies=$n unique_mac=$macs" "R4 / R8 — arping 3 of 3 from ONE MAC"
  else
    row fail "ARP $label $ip one responder 3/3" "replies=$n unique_mac=$macs" "R4 / R8 — arping 3 of 3 from ONE MAC"
  fi
}
arping_check "$HTTP_ADDR" http-gw
arping_check "$GRPC_ADDR" grpc-gw

# 8–9. VIP is a /32 on a node's eth0 (kube-vip's L2 announcement in Docker)
vip_on_eth0() { # ip
  local ip=$1 node out found=""
  for node in $(kind get nodes --name eg-poc1 2>/dev/null); do
    out=$(docker exec "$node" ip -4 addr show eth0 2>/dev/null || true)
    if printf '%s\n' "$out" | grep -q "$ip"; then
      found=$node
      break
    fi
  done
  if [ -n "$found" ]; then
    row ok "VIP $ip on a node's eth0" "node=$found" "R4 — kube-vip announces the /32 on the elected node's eth0"
  else
    row fail "VIP $ip on a node's eth0" "absent" "R4 — kube-vip announces the /32 on the elected node's eth0"
  fi
}
vip_on_eth0 "$HTTP_ADDR"
vip_on_eth0 "$GRPC_ADDR"

# 10. http 200 + X-Served-By
http_door() {
  local hdr code served rc=0
  hdr=$(curl -s --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
    "http://${HTTP_HOST}/healthz" -D - -o /dev/null \
    --connect-timeout 5 --max-time 10 2>/dev/null) || rc=$?
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  served=$(printf '%s' "$hdr" | awk '
    tolower($0) ~ /^[[:space:]]*x-served-by:[[:space:]]*/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }')
  if [ "$code" = 200 ] && [ "$served" = eg-poc1 ]; then
    row ok "http://${HTTP_HOST} 200 + X-Served-By" "http_code=$code X-Served-By=$served" "R8 — 200 and X-Served-By=eg-poc1"
  else
    row fail "http://${HTTP_HOST} 200 + X-Served-By" "http_code=${code:-000} X-Served-By=${served:-absent} curl_rc=$rc" "R8 — 200 and X-Served-By=eg-poc1"
  fi
}
http_door

# 11. https 200, CA file only (do not skip verification)
https_door() {
  local hdr code rc=0
  if [ ! -f "$CA" ]; then
    row fail "https://${HTTP_HOST} 200" "$CA missing" "R8 — 200 against the lab root"
    return
  fi
  hdr=$(curl -s --resolve "${HTTP_HOST}:443:${HTTP_ADDR}" --cacert "$CA" \
    "https://${HTTP_HOST}/healthz" -D - -o /dev/null \
    --connect-timeout 5 --max-time 10 2>/dev/null) || rc=$?
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  if [ "$code" = 200 ]; then
    row ok "https://${HTTP_HOST} 200" "http_code=$code" "R8 — 200 against the lab root"
  else
    row fail "https://${HTTP_HOST} 200" "http_code=${code:-000} curl_rc=$rc" "R8 — 200 against the lab root"
  fi
}
https_door

# 12. /orders 200 (the page behind the door)
orders_door() {
  local hdr code bodyf n rc=0 parse_rc=0
  bodyf=$(mktemp)
  hdr=$(curl -s --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
    -H "Accept: application/json" \
    -D - -o "$bodyf" \
    "http://${HTTP_HOST}/orders" \
    --connect-timeout 5 --max-time 10 2>/dev/null) || rc=$?
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  n=$(python3 -c 'import json,sys
d=json.load(sys.stdin)
if not isinstance(d, list) or len(d) < 1:
    sys.exit(1)
print(len(d))
' <"$bodyf") || parse_rc=$?
  rm -f "$bodyf"
  if [ "$code" = 200 ] && [ "$parse_rc" -eq 0 ]; then
    row ok "http://${HTTP_HOST} /orders 200 (the page behind the door)" \
      "http_code=$code items=$n" \
      "the page behind the door — 200 and a JSON array (≥ 1)"
  else
    row fail "http://${HTTP_HOST} /orders 200 (the page behind the door)" \
      "http_code=${code} items=${n:-?} curl_rc=$rc parse_rc=$parse_rc" \
      "the page behind the door — 200 and a JSON array (≥ 1)"
  fi
}
orders_door

# 13–14. gRPC SERVING via docker grpcurl on kind-eg (no Go cache)
grpc_door() { # tls|h2c
  local mode=$1 out
  if [ "$mode" = h2c ]; then
    out=$(docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
      -plaintext -max-time 10 -authority "$GRPC_HOST" \
      "${GRPC_ADDR}:80" grpc.health.v1.Health/Check 2>&1 || true)
    if printf '%s\n' "$out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"SERVING"'; then
      row ok "gRPC h2c $GRPC_HOST @ ${GRPC_ADDR}:80" "SERVING" "R10 — grpcurl -plaintext Health/Check → SERVING"
    else
      row fail "gRPC h2c $GRPC_HOST @ ${GRPC_ADDR}:80" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" "R10 — grpcurl -plaintext Health/Check → SERVING"
    fi
  else
    if [ ! -f "$CA" ]; then
      row fail "gRPC TLS $GRPC_HOST @ ${GRPC_ADDR}:443" "$CA missing" "R10 — grpcurl -cacert Health/Check → SERVING"
      return
    fi
    out=$(docker run --rm --network kind-eg \
      -v "$PWD/$CA:/ca.crt:ro" fullstorydev/grpcurl:latest \
      -cacert /ca.crt -max-time 10 -authority "$GRPC_HOST" \
      "${GRPC_ADDR}:443" grpc.health.v1.Health/Check 2>&1 || true)
    if printf '%s\n' "$out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"SERVING"'; then
      row ok "gRPC TLS $GRPC_HOST @ ${GRPC_ADDR}:443" "SERVING" "R10 — grpcurl -cacert Health/Check → SERVING"
    else
      row fail "gRPC TLS $GRPC_HOST @ ${GRPC_ADDR}:443" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" "R10 — grpcurl -cacert Health/Check → SERVING"
    fi
  fi
}
grpc_door h2c
grpc_door tls

# 15. stock networking — capture then count (a failed kubectl is not "0 Cilium")
if ds_all=$(kubectl --context "$CTX" get ds -A -o name 2>/dev/null) \
   && crd_all=$(kubectl --context "$CTX" get crd -o name 2>/dev/null) \
   && kp_yaml=$(kubectl --context "$CTX" -n kube-system get cm kube-proxy -o yaml 2>/dev/null); then
  cilium_ds=$(printf '%s\n' "$ds_all" | grep -c cilium || true)
  cilium_crd=$(printf '%s\n' "$crd_all" | grep -c cilium || true)
  mode=$(printf '%s\n' "$kp_yaml" | awk '/^[[:space:]]*mode:/{print $2; exit}')
  if [ "$mode" = iptables ] && [ "$cilium_ds" -eq 0 ] && [ "$cilium_crd" -eq 0 ]; then
    row ok "stock networking" "kube-proxy=$mode cilium_ds=$cilium_ds cilium_crd=$cilium_crd" "R2 — kube-proxy iptables, 0 Cilium DS/CRD"
  else
    row fail "stock networking" "kube-proxy=${mode:-?} cilium_ds=$cilium_ds cilium_crd=$cilium_crd" "R2 — kube-proxy iptables, 0 Cilium DS/CRD"
  fi
else
  row fail "stock networking" "kubectl get ds/crd/cm failed" "R2 — kube-proxy iptables, 0 Cilium DS/CRD"
fi

echo
echo "demo 54 check: $fails FAIL"
exit "$fails"
