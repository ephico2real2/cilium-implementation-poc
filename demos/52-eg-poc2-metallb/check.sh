#!/usr/bin/env bash
# check.sh — demo 52 PASS/FAIL rows (demo 54's row() style). Exit = FAIL count.
# At most 21 rows. A failed kubectl is a FAIL, never a PASS.
#   demos/52-eg-poc2-metallb/check.sh
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

CTX=kind-eg-poc2
CA=.tmp/eg-poc2-root-ca.crt
ML_CLASS=metallb.io/metallb
HTTP_ADDR=172.19.255.150
GRPC_ADDR=172.19.255.151
HTTP_HOST=api.eg-poc2.poc.local
GRPC_HOST=grpc.eg-poc2.poc.local
CLUSTER=eg-poc2

printf '\n== demo 52 — one cluster, MetalLB, two Gateways (HTTP isolated from gRPC)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# 1. MetalLB controller Available + speaker DS rolled out
ctrl_out=$(kubectl --context "$CTX" -n metallb-system get deploy \
  -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>&1)
ctrl_rc=$?
spk_out=$(kubectl --context "$CTX" -n metallb-system get ds \
  -l app.kubernetes.io/component=speaker \
  -o jsonpath='{.items[0].status.numberReady}/{.items[0].status.desiredNumberScheduled}' 2>&1)
spk_rc=$?
if [ "$ctrl_rc" -ne 0 ] || [ "$spk_rc" -ne 0 ]; then
  row fail "MetalLB controller Available + speaker DS" \
    "kubectl failed ctrl_rc=$ctrl_rc spk_rc=$spk_rc" \
    "R5 — controller Available, speaker N/N (chart 0.16.0, --lb-class)"
elif [ "$ctrl_out" = True ] \
   && printf '%s' "$spk_out" | grep -Eq '^[0-9]+/[0-9]+$' \
   && [ "${spk_out%%/*}" = "${spk_out#*/}" ] && [ "${spk_out%%/*}" -gt 0 ]; then
  row ok "MetalLB controller Available + speaker DS" \
    "Available=$ctrl_out ready=$spk_out" \
    "R5 — controller Available, speaker N/N (chart 0.16.0, --lb-class)"
else
  row fail "MetalLB controller Available + speaker DS" \
    "Available=${ctrl_out:-?} ready=${spk_out:-?}" \
    "R5 — controller Available, speaker N/N (chart 0.16.0, --lb-class)"
fi

# 2–3. Gateways Programmed at the pinned address with Service ingress
expect_gw() { # name want_addr
  local name=$1 want=$2 addr prog svc_ingress gw_err svc_err

  gw_err=$(kubectl --context "$CTX" -n shop get gateway "$name" \
    -o jsonpath='{.status.addresses[0].value}{"|"}{.status.conditions[?(@.type=="Programmed")].status}' 2>&1)
  if [ $? -ne 0 ]; then
    row fail "$name Programmed at $want" "kubectl failed: $(printf '%s' "$gw_err" | tr '\n' ' ' | head -c 60)" \
      "R5 / R8 — Gateway address and Service ingress must both be $want"
    return
  fi
  addr=${gw_err%%|*}
  prog=${gw_err#*|}

  svc_err=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$name" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>&1)
  if [ $? -ne 0 ]; then
    row fail "$name Programmed at $want" "kubectl svc failed: $(printf '%s' "$svc_err" | tr '\n' ' ' | head -c 60)" \
      "R5 / R8 — Gateway address and Service ingress must both be $want"
    return
  fi
  svc_ingress=$svc_err

  if [ "$prog" = True ] && [ "$addr" = "$want" ] && [ "$svc_ingress" = "$want" ]; then
    row ok "$name Programmed at $want" \
      "addr=$addr svcIngress=$svc_ingress Programmed=$prog" \
      "R5 / R8 — Gateway address and Service ingress both equal $want"
  else
    row fail "$name Programmed at $want" \
      "addr=${addr:-?} svcIngress=${svc_ingress:-?} Programmed=${prog:-?}" \
      "R5 / R8 — Gateway address and Service ingress both equal $want"
  fi
}
expect_gw http-gw "$HTTP_ADDR"
expect_gw grpc-gw "$GRPC_ADDR"

# 4. both Envoy Services carry the class
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
    "D11 — EnvoyProxy names metallb.io/metallb on both doors"
elif [ "$class_http" = "$ML_CLASS" ] && [ "$class_grpc" = "$ML_CLASS" ]; then
  row ok "both Envoy Services carry the class" "http=$class_http grpc=$class_grpc" \
    "D11 — EnvoyProxy names metallb.io/metallb on both doors"
else
  row fail "both Envoy Services carry the class" "http=${class_http:-?} grpc=${class_grpc:-?}" \
    "D11 — EnvoyProxy names metallb.io/metallb on both doors"
fi

# 5–6. ARP one responder 3/3, every probe a broadcast. MAC mapped to a kind node.
node_of_mac() { # mac → node name on kind-eg, or ""
  local want node nmac
  want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for node in $(kind get nodes --name "$CLUSTER" 2>/dev/null); do
    nmac=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").MacAddress}}' "$node" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]')
    if [ -n "$nmac" ] && [ "$nmac" = "$want" ]; then
      printf '%s' "$node"
      return 0
    fi
  done
  return 1
}
arping_check() { # ip label
  local ip=$1 label=$2 out n macs mac node
  out=$(docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -b -c 3 -I eth0 "$ip" 2>&1 || true)
  n=$(printf '%s\n' "$out" | grep -c 'Unicast reply' || true)
  macs=$(printf '%s\n' "$out" | awk '/Unicast reply/{gsub(/[\[\]]/,"",$5); print $5}' | sort -u | wc -l | tr -d ' ')
  mac=$(printf '%s\n' "$out" | awk '/Unicast reply/{gsub(/[\[\]]/,"",$5); print $5; exit}')
  node=$(node_of_mac "$mac" || true)
  if [ "$n" -eq 3 ] && [ "$macs" -eq 1 ]; then
    row ok "ARP $label $ip one responder 3/3" "replies=$n unique_mac=$macs node=${node:-?}" "R5 / R8 — arping -b 3 of 3 from ONE MAC"
  else
    row fail "ARP $label $ip one responder 3/3" "replies=$n unique_mac=$macs node=${node:-?}" "R5 / R8 — arping -b 3 of 3 from ONE MAC"
  fi
}
arping_check "$HTTP_ADDR" http-gw
arping_check "$GRPC_ADDR" grpc-gw

# 7. VIP .150 NOT on any node's eth0 — MetalLB answers ARP, does not add the address.
vip_absent() {
  local ip=$HTTP_ADDR nodes out found="" node
  nodes=$(kind get nodes --name "$CLUSTER" 2>&1)
  if [ $? -ne 0 ] || [ -z "$nodes" ]; then
    row fail "VIP $ip NOT on any node's eth0" "kind failed: $(printf '%s' "$nodes" | tr '\n' ' ' | head -c 60)" \
      "R5 — MetalLB does not add the address to eth0"
    return
  fi
  for node in $nodes; do
    out=$(docker exec "$node" ip -4 addr show eth0 2>&1) || {
      row fail "VIP $ip NOT on any node's eth0" "docker exec $node failed" \
        "R5 — MetalLB does not add the address to eth0"
      return
    }
    if ! printf '%s' "$out" | grep -q 'inet '; then
      row fail "VIP $ip NOT on any node's eth0" "docker exec $node did not return ip addr" \
        "R5 — MetalLB does not add the address to eth0"
      return
    fi
    if printf '%s\n' "$out" | grep -Eq "^[[:space:]]*inet ${ip//./\\.}"; then
      found="${found}${node} "
    fi
  done
  if [ -z "$found" ]; then
    row ok "VIP $ip NOT on any node's eth0" "absent on all nodes" \
      "R5 — MetalLB answers ARP; kube-proxy delivers; no /32 on eth0"
  else
    row fail "VIP $ip NOT on any node's eth0" "present on $found" \
      "R5 — MetalLB answers ARP; kube-proxy delivers; no /32 on eth0"
  fi
}
vip_absent

# 8. ServiceL2Status / announcing from node
l2_status() {
  local crd out
  crd=$(kubectl --context "$CTX" get crd servicel2statuses.metallb.io -o name 2>&1)
  if [ $? -ne 0 ]; then
    row fail "ServiceL2Status / announcing from node" \
      "kubectl failed: $(printf '%s' "$crd" | tr '\n' ' ' | head -c 60)" \
      "R5 — MetalLB names the announcing node"
    return
  fi
  if printf '%s' "$crd" | grep -q servicel2statuses.metallb.io; then
    # MetalLB writes ServiceL2Status in ITS namespace (measured 2026-09-19: metallb-system,
    # status.serviceName / .serviceNamespace / .node) — not beside the Service.
    out=$(kubectl --context "$CTX" -n metallb-system get servicel2status -o json 2>&1)
    if [ $? -ne 0 ]; then
      row fail "ServiceL2Status / announcing from node" \
        "kubectl failed: $(printf '%s' "$out" | tr '\n' ' ' | head -c 60)" \
        "R5 — MetalLB names the announcing node"
      return
    fi
    measured=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    print("bad json"); sys.exit(0)
want = {"envoy-shop-http-gw", "envoy-shop-grpc-gw"}
seen = {}
for it in items:
    st = it.get("status", {})
    name = st.get("serviceName", "")
    for w in want:
        if name.startswith(w) and st.get("node"):
            seen[w] = st["node"]
print(" ".join(f"{k}={v}" for k, v in sorted(seen.items())) if len(seen) == 2 else "missing: " + " ".join(sorted(want - set(seen))))
' 2>/dev/null)
    case "$measured" in
      *http-gw=*grpc-gw=*|*grpc-gw=*http-gw=*)
        row ok "ServiceL2Status / announcing from node" "$measured" \
          "R5 — MetalLB names the announcing node for both doors" ;;
      *)
        row fail "ServiceL2Status / announcing from node" "${measured:-no ServiceL2Status}" \
          "R5 — MetalLB names the announcing node for both doors" ;;
    esac
  else
    out=$(kubectl --context "$CTX" -n metallb-system logs \
      -l app.kubernetes.io/component=speaker --tail=-1 --prefix 2>&1)
    if [ $? -ne 0 ]; then
      row fail "ServiceL2Status / announcing from node" \
        "speaker logs failed: $(printf '%s' "$out" | tr '\n' ' ' | head -c 60)" \
        "R5 — speaker announcing from node (CRD absent)"
      return
    fi
    if printf '%s' "$out" | grep -qF "announcing from node"; then
      row ok "ServiceL2Status / announcing from node" "speaker announcing from node" \
        "R5 — speaker announcing from node (CRD absent)"
    else
      row fail "ServiceL2Status / announcing from node" "no announcing from node in speaker log" \
        "R5 — speaker announcing from node (CRD absent)"
    fi
  fi
}
l2_status

# 9. http 200 + X-Served-By
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
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ] && [ "$served" = eg-poc2 ]; then
    row ok "http://${HTTP_HOST} 200 + X-Served-By" "http_code=$code X-Served-By=$served" "R8 — 200 and X-Served-By=eg-poc2"
  else
    row fail "http://${HTTP_HOST} 200 + X-Served-By" "http_code=${code:-000} X-Served-By=${served:-absent} curl_rc=$rc" "R8 — 200 and X-Served-By=eg-poc2"
  fi
}
http_door

# 10. https 200, CA file only (do not skip verification)
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
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
    row ok "https://${HTTP_HOST} 200" "http_code=$code" "R8 — 200 against the lab root"
  else
    row fail "https://${HTTP_HOST} 200" "http_code=${code:-000} curl_rc=$rc" "R8 — 200 against the lab root"
  fi
}
https_door

# 11. /orders 200
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
' <"$bodyf" 2>/dev/null) || parse_rc=$?
  rm -f "$bodyf"
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ] && [ "$parse_rc" -eq 0 ]; then
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

# docker grpcurl on kind-eg (no Go cache)
grpc_docker() { # extra args... -- method
  docker run --rm --network kind-eg fullstorydev/grpcurl:latest "$@" 2>&1 || true
}
grpc_docker_tls() {
  docker run --rm --network kind-eg \
    -v "$PWD/$CA:/ca.crt:ro" fullstorydev/grpcurl:latest "$@" 2>&1 || true
}
grpc_docker_probe() {
  docker run --rm --network kind-eg \
    -v "$PWD/demos/52-eg-poc2-metallb/probe:/probe:ro" \
    fullstorydev/grpcurl:latest "$@" 2>&1 || true
}

# 12. Health SERVING (exact "status": "SERVING")
health_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  "${GRPC_ADDR}:80" grpc.health.v1.Health/Check)
if printf '%s\n' "$health_out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"SERVING"'; then
  row ok "gRPC Health \"\" SERVING" "SERVING" "R10 — exact \"status\": \"SERVING\""
else
  row fail "gRPC Health \"\" SERVING" "$(printf '%s' "$health_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — exact \"status\": \"SERVING\""
fi

# 13. ListOrders v1
list_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders)
if printf '%s' "$list_out" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"v1"' \
   && printf '%s' "$list_out" | grep -q keyboard; then
  row ok "gRPC ListOrders v1" "version=v1" "R10 — service default → grpc-v1"
else
  row fail "gRPC ListOrders v1" "$(printf '%s' "$list_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — service default → grpc-v1"
fi

# 14. GetOrder v2 (routing by method) — a stub {"version":"v1"} is FAIL
get_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  -d '{"id":2}' "${GRPC_ADDR}:80" shop.v1.Orders/GetOrder)
if printf '%s' "$get_out" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"v2"'; then
  row ok "gRPC GetOrder v2" "version=v2" "R10 — method match → grpc-v2"
else
  row fail "gRPC GetOrder v2" "$(printf '%s' "$get_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — method match → grpc-v2"
fi

# 15. x-version v2 (routing by metadata)
hdr_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  -H 'x-version: v2' "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders)
if printf '%s' "$hdr_out" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"v2"'; then
  row ok "gRPC ListOrders x-version v2" "version=v2" "R10 — metadata match → grpc-v2"
else
  row fail "gRPC ListOrders x-version v2" "$(printf '%s' "$hdr_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — metadata match → grpc-v2"
fi

# 16. WatchOrders 5 events
watch_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  -d '{"count":5,"interval_ms":200}' "${GRPC_ADDR}:80" shop.v1.Orders/WatchOrders)
watch_n=$(printf '%s\n' "$watch_out" | grep -c '"item"' || true)
if [ "$watch_n" -eq 5 ]; then
  row ok "gRPC WatchOrders 5 events" "events=$watch_n" "R10 — streamed OrderEvent × 5"
else
  row fail "gRPC WatchOrders 5 events" "events=$watch_n" "R10 — streamed OrderEvent × 5"
fi

# 17. NotFound
nf_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  -d '{"id":99}' "${GRPC_ADDR}:80" shop.v1.Orders/GetOrder)
if printf '%s' "$nf_out" | grep -Eq 'NotFound'; then
  row ok "gRPC GetOrder NotFound" "NotFound" "R10 — unknown id → Code: NotFound"
else
  row fail "gRPC GetOrder NotFound" "$(printf '%s' "$nf_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — unknown id → Code: NotFound"
fi

# 18. Unimplemented — T8a: missing method on a routed service (descriptor, no reflection)
un_out=$(grpc_docker_probe -plaintext -max-time 10 \
  -import-path /probe -proto probe.proto \
  -authority "$GRPC_HOST" \
  "${GRPC_ADDR}:80" shop.v1.Orders/NoSuchMethod)
if printf '%s' "$un_out" | grep -Eq 'Code:[[:space:]]*Unimplemented' \
   && printf '%s' "$un_out" | grep -q 'unknown method NoSuchMethod for service shop.v1.Orders'; then
  row ok "gRPC NoSuchMethod Unimplemented" "Unimplemented unknown method" \
    "R10 — missing method → Code: Unimplemented + unknown method"
else
  row fail "gRPC NoSuchMethod Unimplemented" "$(printf '%s' "$un_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — missing method → Code: Unimplemented + unknown method"
fi

# 19. Unimplemented — T8b: unrouted service → Unimplemented with an empty Message
nope_out=$(grpc_docker_probe -plaintext -max-time 10 \
  -import-path /probe -proto nope.proto \
  -authority "$GRPC_HOST" \
  "${GRPC_ADDR}:80" shop.v1.Nope/Do)
if printf '%s' "$nope_out" | grep -Eq 'Code:[[:space:]]*Unimplemented' \
   && printf '%s\n' "$nope_out" | grep -Eq 'Message:[[:space:]]*$'; then
  row ok "gRPC unrouted service Unimplemented" "Unimplemented empty Message" \
    "R10 — unrouted service → Code: Unimplemented + empty Message"
else
  row fail "gRPC unrouted service Unimplemented" "$(printf '%s' "$nope_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — unrouted service → Code: Unimplemented + empty Message"
fi

# 20. DeadlineExceeded
de_out=$(grpc_docker -plaintext -max-time 1 -authority "$GRPC_HOST" \
  -d '{"delay_ms":3000}' "${GRPC_ADDR}:80" shop.v1.Orders/SlowOrder)
if printf '%s' "$de_out" | grep -Eq 'DeadlineExceeded'; then
  row ok "gRPC SlowOrder DeadlineExceeded" "DeadlineExceeded" "R10 — -max-time 1 vs delay_ms 3000"
else
  row fail "gRPC SlowOrder DeadlineExceeded" "$(printf '%s' "$de_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — -max-time 1 vs delay_ms 3000"
fi

# 21. TLS ListOrders
if [ ! -f "$CA" ]; then
  row fail "gRPC TLS ListOrders" "$CA missing" "R10 — TLS ListOrders against the lab root"
else
  tls_out=$(grpc_docker_tls -cacert /ca.crt -max-time 10 -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:443" shop.v1.Orders/ListOrders)
  if printf '%s' "$tls_out" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"v1"'; then
    row ok "gRPC TLS ListOrders" "version=v1" "R10 — TLS ListOrders against the lab root"
  else
    row fail "gRPC TLS ListOrders" "$(printf '%s' "$tls_out" | tr '\n' ' ' | head -c 80)" \
      "R10 — TLS ListOrders against the lab root"
  fi
fi

echo
echo "demo 52 check: $fails FAIL"
exit "$fails"
