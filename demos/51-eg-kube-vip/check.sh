#!/usr/bin/env bash
# check.sh — demo 51 PASS/FAIL rows (demo 40's row() style). Exit = FAIL count.
#   demos/51-eg-kube-vip/check.sh
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

CA=.tmp/eg-root-ca.crt
KV_CLASS=kube-vip.io/kube-vip-class
VIP=172.19.255.16
EG1_GW=172.19.255.240
EG2_GW=172.19.255.176

printf '\n== demo 51 — Envoy Gateway with kube-vip — alone (enhancement 007 phase 2)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# R4 — kube-vip DS ready + cloud-provider Available (both); NO metallb-system
for ctx in kind-eg1 kind-eg2; do
  c=${ctx#kind-}
  ds=$(kubectl --context "$ctx" -n kube-system get ds kube-vip-ds \
    -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)
  if [ -n "$ds" ] && [ "${ds#*/}" != "0" ] && [ "${ds%%/*}" = "${ds#*/}" ]; then
    row ok "$c kube-vip DS ready" "ready=$ds" "R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)"
  else
    row fail "$c kube-vip DS ready" "ready=${ds:-absent}" "R4 — kube-vip-ds ready (v1.2.4, lb_class_only, no taint)"
  fi
  cp_av=$(kubectl --context "$ctx" -n kube-system get deploy kube-vip-cloud-provider \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  if [ "$cp_av" = True ]; then
    row ok "$c kube-vip-cloud-provider Available" "Available=$cp_av" "R4 — cloud-provider v0.0.12 Available (KUBEVIP_ENABLE_LOADBALANCERCLASS=true)"
  else
    row fail "$c kube-vip-cloud-provider Available" "Available=${cp_av:-?}" "R4 — cloud-provider v0.0.12 Available (KUBEVIP_ENABLE_LOADBALANCERCLASS=true)"
  fi
  if ns_out=$(kubectl --context "$ctx" get ns metallb-system -o name 2>&1); then
    row fail "$c no metallb-system namespace" "$ns_out" "R4 — MetalLB is demo 52; kubectl get ns metallb-system must not exist"
  else
    row ok "$c no metallb-system namespace" "NotFound" "R4 — MetalLB is demo 52; kubectl get ns metallb-system must not exist"
  fi
done

# R4 / §3.1 — kubevip ranges
expect_range() { # ctx key want
  local ctx=$1 key=$2 want=$3 got
  got=$(kubectl --context "$ctx" -n kube-system get cm kubevip -o jsonpath="{.data.$key}" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then
    row ok "${ctx#kind-} kubevip $key" "$got" "R4 / §3.1 — $key=$want"
  else
    row fail "${ctx#kind-} kubevip $key" "got=${got:-?} want=$want" "R4 / §3.1 — $key=$want"
  fi
}
expect_range kind-eg1 range-envoy-gateway-system 172.19.255.240-172.19.255.245
expect_range kind-eg1 range-default 172.19.255.200-172.19.255.205
expect_range kind-eg2 range-envoy-gateway-system 172.19.255.176-172.19.255.181
expect_range kind-eg2 range-default 172.19.255.136-172.19.255.141

# R4 / R8 — every Gateway Programmed with its address
expect_gw() { # ctx name want_addr
  local ctx=$1 name=$2 want=$3 addr prog
  if ! kubectl --context "$ctx" -n shop get gateway "$name" >/dev/null 2>&1; then
    if [ "$name" = eg-vip-gw ]; then
      return 0
    fi
    row fail "${ctx#kind-}/$name Programmed at $want" "absent" "R4 / R8 — Programmed=True and status.addresses[0]=$want"
    return
  fi
  addr=$(kubectl --context "$ctx" -n shop get gateway "$name" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  prog=$(kubectl --context "$ctx" -n shop get gateway "$name" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  if [ "$prog" = True ] && [ "$addr" = "$want" ]; then
    row ok "${ctx#kind-}/$name Programmed at $want" "addr=$addr Programmed=$prog" "R4 / R8 — Programmed=True and status.addresses[0]=$want"
  else
    row fail "${ctx#kind-}/$name Programmed at $want" "addr=${addr:-?} Programmed=${prog:-?}" "R4 / R8 — Programmed=True and status.addresses[0]=$want"
  fi
}
expect_gw kind-eg1 eg1-gw "$EG1_GW"
expect_gw kind-eg1 eg-vip-gw "$VIP"
expect_gw kind-eg2 eg2-gw "$EG2_GW"
expect_gw kind-eg2 eg-vip-gw "$VIP"

# D11 — every Gateway Service has the kube-vip class
expect_class() { # ctx gw
  local ctx=$1 gw=$2 klass
  if ! kubectl --context "$ctx" -n shop get gateway "$gw" >/dev/null 2>&1; then
    return 0
  fi
  klass=$(kubectl --context "$ctx" -n envoy-gateway-system get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
    -o jsonpath='{.items[0].spec.loadBalancerClass}' 2>/dev/null || true)
  if [ "$klass" = "$KV_CLASS" ]; then
    row ok "${ctx#kind-}/$gw Service loadBalancerClass" "$klass" "D11 — EnvoyProxy names kube-vip.io/kube-vip-class"
  else
    row fail "${ctx#kind-}/$gw Service loadBalancerClass" "got=${klass:-?}" "D11 — EnvoyProxy names kube-vip.io/kube-vip-class"
  fi
}
expect_class kind-eg1 eg1-gw
expect_class kind-eg1 eg-vip-gw
expect_class kind-eg2 eg2-gw
expect_class kind-eg2 eg-vip-gw

# D11 — standing exhibit probe-noclass stays <pending> (applied by apply.sh)
for ctx in kind-eg1 kind-eg2; do
  c=${ctx#kind-}
  typ=$(kubectl --context "$ctx" -n shop get svc probe-noclass -o jsonpath='{.spec.type}' 2>/dev/null || true)
  klass=$(kubectl --context "$ctx" -n shop get svc probe-noclass -o jsonpath='{.spec.loadBalancerClass}' 2>/dev/null || true)
  ing=$(kubectl --context "$ctx" -n shop get svc probe-noclass -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ "$typ" = LoadBalancer ] && [ -z "$klass" ] && [ -z "$ing" ]; then
    row ok "$c probe-noclass stays pending" "type=$typ class=${klass:-(none)} ingress=${ing:-(none)}" "D11 — class-less LoadBalancer Service stays <pending>"
  else
    row fail "$c probe-noclass stays pending" "type=${typ:-?} class=${klass:-?} ingress=${ing:-?}" "D11 — class-less LoadBalancer Service stays <pending>"
  fi
done

# R4 / R7 — one ARP responder per address, 3 of 3 from ONE MAC
arping_check() { # ip label
  local ip=$1 label=$2 out n macs
  out=$(docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -c 3 -I eth0 "$ip" 2>&1 || true)
  n=$(printf '%s\n' "$out" | grep -c 'Unicast reply' || true)
  macs=$(printf '%s\n' "$out" | awk '/Unicast reply/{gsub(/[\[\]]/,"",$5); print $5}' | sort -u | wc -l | tr -d ' ')
  if [ "$n" -eq 3 ] && [ "$macs" -eq 1 ]; then
    row ok "ARP $label $ip one responder 3/3" "replies=$n unique_mac=$macs" "R4 / R7 — arping 3 of 3 from ONE MAC"
  else
    row fail "ARP $label $ip one responder 3/3" "replies=$n unique_mac=$macs" "R4 / R7 — arping 3 of 3 from ONE MAC"
  fi
}
arping_check "$EG1_GW" eg1-gw
arping_check "$EG2_GW" eg2-gw
arping_check "$VIP" eg-vip-gw

# R4 / §3.4 — VIP present in exactly one cluster
n1=0; n2=0
kubectl --context kind-eg1 -n shop get gateway eg-vip-gw >/dev/null 2>&1 && n1=1
kubectl --context kind-eg2 -n shop get gateway eg-vip-gw >/dev/null 2>&1 && n2=1
if [ $((n1 + n2)) -eq 1 ]; then
  if [ "$n1" -eq 1 ]; then
    row ok "VIP Gateway in exactly one cluster" "eg1" "R4 / §3.4 — shared address lives where it is announced"
  else
    row ok "VIP Gateway in exactly one cluster" "eg2" "R4 / §3.4 — shared address lives where it is announced"
  fi
else
  row fail "VIP Gateway in exactly one cluster" "eg1=$n1 eg2=$n2" "R4 / §3.4 — shared address lives where it is announced"
fi

# R8 — three https doors 200 + X-Served-By
https_door() { # host addr want_header
  local host=$1 addr=$2 want=$3 hdr code served
  hdr=$(curl -sk --resolve "$host:443:$addr" --cacert "$CA" \
    "https://$host/healthz" -D - -o /dev/null --connect-timeout 5 --max-time 10 2>/dev/null || true)
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  served=$(printf '%s' "$hdr" | awk '
    tolower($0) ~ /^[[:space:]]*x-served-by:[[:space:]]*/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }')
  if [ "$code" = 200 ] && [ -n "$served" ]; then
    if [ -n "$want" ] && [ "$served" != "$want" ]; then
      row fail "https://$host @ $addr 200 + X-Served-By" "http_code=$code X-Served-By=$served want=$want" "R8 — 200 and X-Served-By=$want"
    else
      row ok "https://$host @ $addr 200 + X-Served-By" "http_code=$code X-Served-By=$served" "R8 — 200 and X-Served-By present"
    fi
  else
    row fail "https://$host @ $addr 200 + X-Served-By" "http_code=${code:-000} X-Served-By=${served:-absent}" "R8 — 200 and X-Served-By present"
  fi
  if [ -z "$served" ]; then
    row fail "X-Served-By never absent on $host" "absent" "R8 — the Gateway filter SET the header"
  else
    row ok "X-Served-By never absent on $host" "X-Served-By=$served" "R8 — the Gateway filter SET the header"
  fi
}
https_door api.eg1.poc.local "$EG1_GW" eg1
https_door api.eg2.poc.local "$EG2_GW" eg2
https_door api.eg.poc.local "$VIP" ""

# R8 — three 301s
redirect_door() { # host addr
  local host=$1 addr=$2 code
  code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$host:80:$addr" \
    "http://$host/healthz" --connect-timeout 5 --max-time 10 2>/dev/null || echo 000)
  if [ "$code" = 301 ]; then
    row ok "http://$host @ $addr → 301" "http_code=$code" "R8 — shop-redirect on the :80 listener"
  else
    row fail "http://$host @ $addr → 301" "http_code=${code:-000}" "R8 — shop-redirect on the :80 listener"
  fi
}
redirect_door api.eg1.poc.local "$EG1_GW"
redirect_door api.eg2.poc.local "$EG2_GW"
redirect_door api.eg.poc.local "$VIP"

# R10 — gRPC SERVING h2c + TLS on every door
grpc_door() { # authority addr label
  local auth=$1 addr=$2 label=$3 out
  out=$(docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
    -plaintext -max-time 10 -authority "$auth" \
    "${addr}:80" grpc.health.v1.Health/Check 2>&1 || true)
  if printf '%s' "$out" | grep -q SERVING; then
    row ok "gRPC h2c $label $auth @ $addr:80" "SERVING" "R10 — grpcurl -plaintext Health/Check → SERVING"
  else
    row fail "gRPC h2c $label $auth @ $addr:80" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" "R10 — grpcurl -plaintext Health/Check → SERVING"
  fi
  if [ ! -f "$CA" ]; then
    row fail "gRPC TLS $label $auth @ $addr:443" "$CA missing" "R10 — grpcurl -cacert .tmp/eg-root-ca.crt Health/Check → SERVING"
    return
  fi
  out=$(docker run --rm --network kind-eg \
    -v "$PWD/$CA:/ca.crt:ro" fullstorydev/grpcurl:latest \
    -cacert /ca.crt -max-time 10 -authority "$auth" \
    "${addr}:443" grpc.health.v1.Health/Check 2>&1 || true)
  if printf '%s' "$out" | grep -q SERVING; then
    row ok "gRPC TLS $label $auth @ $addr:443" "SERVING" "R10 — grpcurl -cacert .tmp/eg-root-ca.crt Health/Check → SERVING"
  else
    row fail "gRPC TLS $label $auth @ $addr:443" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" "R10 — grpcurl -cacert .tmp/eg-root-ca.crt Health/Check → SERVING"
  fi
}
grpc_door grpc.eg1.poc.local "$EG1_GW" eg1-gw
grpc_door grpc.eg2.poc.local "$EG2_GW" eg2-gw
grpc_door grpc.eg.poc.local "$VIP" eg-vip-gw

# D8 / R8 — certificate Ready with the six SANs
want_sans="api.eg.poc.local api.eg1.poc.local api.eg2.poc.local grpc.eg1.poc.local grpc.eg2.poc.local grpc.eg.poc.local"
for ctx in kind-eg1 kind-eg2; do
  c=${ctx#kind-}
  ready=$(kubectl --context "$ctx" -n shop get certificate eg-tls \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  sans=$(kubectl --context "$ctx" -n shop get secret eg-tls \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d \
    | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)
  missing=""
  for n in $want_sans; do
    printf '%s' "$sans" | grep -q "$n" || missing="$missing $n"
  done
  if [ "$ready" = True ] && [ -z "$missing" ]; then
    row ok "$c certificate eg-tls Ready with six SANs" "Ready=$ready" "D8 / R8 — CN api.eg.poc.local, six dnsNames, issuer eg-ca-issuer"
  else
    row fail "$c certificate eg-tls Ready with six SANs" "Ready=${ready:-?} missing=${missing:-none}" "D8 / R8 — CN api.eg.poc.local, six dnsNames, issuer eg-ca-issuer"
  fi
done

echo
echo "demo 51 check: $fails FAIL"
exit "$fails"
