#!/usr/bin/env bash
# check.sh — demo 52 PASS/FAIL rows (demo 54's row() style). Exit = FAIL count.
# At most 21 rows. A failed kubectl is a FAIL, never a PASS.
#   demos/52-eg-poc2-metallb/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
fails=0
payload_ok() {
  python3 -c '
import json, sys
try:
    kind, version, rc = sys.argv[1:]
    assert rc == "0"
    text = sys.stdin.read().strip()
    decoder = json.JSONDecoder()
    values = []
    while text:
        value, end = decoder.raw_decode(text)
        values.append(value)
        text = text[end:].lstrip()
    def stamp(value):
        assert isinstance(value, dict)
        assert value.get("version") == version
        assert isinstance(value.get("servedBy"), str)
        assert value["servedBy"].startswith("grpcdemo-" + version + "-")
    def order(value):
        stamp(value)
        assert str(value.get("id")) in ("1", "2", "3")
        assert value.get("item") == {"1":"keyboard","2":"mouse","3":"monitor"}[str(value["id"])]
    if kind == "list":
        assert len(values) == 1
        stamp(values[0])
        orders = values[0]["orders"]
        assert isinstance(orders, list) and len(orders) == 3
        assert {str(o["id"]) for o in orders} == {"1", "2", "3"}
        for value in orders:
            order(value)
        count = 3
    elif kind == "get":
        assert len(values) == 1
        order(values[0])
        assert str(values[0]["id"]) == "2"
        count = 1
    elif kind == "stream":
        assert len(values) == 5
        for value in values:
            stamp(value)
            order(value["order"])
        count = 5
    else:
        raise ValueError("unknown payload kind")
    print(count)
except (AssertionError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    sys.exit(1)
' "$@"
}
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
  # the responder must be an eg-poc2 node: a MAC no node owns (a stale container, a
  # neighbour cluster on the same /26) is "3/3 from one MAC" too and is not this
  # lab's announcement — never "PASS node=?"
  if [ "$n" -eq 3 ] && [ "$macs" -eq 1 ] && [ -n "$node" ]; then
    row ok "ARP $label $ip one responder 3/3" "replies=$n unique_mac=$macs node=$node" "R5 / R8 — arping -b 3 of 3 from ONE MAC"
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
    # The door Services are externalTrafficPolicy: Local (Envoy Gateway's default), so
    # MetalLB's L2 election only considers nodes with a serving endpoint
    # (speaker/layer2_controller.go v0.16.0 ShouldAnnounce: nodesWithEndpoint). The
    # announcing node must therefore be a node that runs the door's Envoy pod.
    pod_nodes_http=$(kubectl --context "$CTX" -n envoy-gateway-system get pods \
      -l gateway.envoyproxy.io/owning-gateway-name=http-gw -o jsonpath='{.items[*].spec.nodeName}' 2>&1)
    pod_rc_http=$?
    pod_nodes_grpc=$(kubectl --context "$CTX" -n envoy-gateway-system get pods \
      -l gateway.envoyproxy.io/owning-gateway-name=grpc-gw -o jsonpath='{.items[*].spec.nodeName}' 2>&1)
    pod_rc_grpc=$?
    if [ "$pod_rc_http" -ne 0 ] || [ "$pod_rc_grpc" -ne 0 ]; then
      row fail "ServiceL2Status / announcing from node" \
        "kubectl pods failed http_rc=$pod_rc_http grpc_rc=$pod_rc_grpc" \
        "R5 — MetalLB names the announcing node for both doors (ETP Local: a node with the Envoy pod)"
      return
    fi
    measured=$(printf '%s' "$out" | POD_NODES_HTTP="$pod_nodes_http" POD_NODES_GRPC="$pod_nodes_grpc" python3 -c '
import json, os, sys
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    print("bad json"); sys.exit(0)
pod_nodes = {"envoy-shop-http-gw": set(os.environ["POD_NODES_HTTP"].split()),
             "envoy-shop-grpc-gw": set(os.environ["POD_NODES_GRPC"].split())}
want = set(pod_nodes)
seen, wrong = {}, []
for it in items:
    st = it.get("status", {})
    name = st.get("serviceName", "")
    for w in want:
        if name.startswith(w) and st.get("node"):
            seen[w] = st["node"]
            if st["node"] not in pod_nodes[w]:
                wrong.append("%s=%s pod on %s" % (w, st["node"], " ".join(sorted(pod_nodes[w])) or "?"))
if len(seen) != 2:
    print("missing: " + " ".join(sorted(want - set(seen))))
elif wrong:
    print("not the pod node: " + " ".join(wrong))
else:
    print(" ".join(f"{k}={v}" for k, v in sorted(seen.items())))
' 2>/dev/null)
    case "$measured" in
      missing:*|not\ the\ pod\ node:*|"bad json"|"")
        row fail "ServiceL2Status / announcing from node" "${measured:-no ServiceL2Status}" \
          "R5 — MetalLB names the announcing node for both doors (ETP Local: a node with the Envoy pod)" ;;
      *http-gw=*grpc-gw=*|*grpc-gw=*http-gw=*)
        row ok "ServiceL2Status / announcing from node" "$measured" \
          "R5 — MetalLB names the announcing node for both doors (ETP Local: a node with the Envoy pod)" ;;
      *)
        row fail "ServiceL2Status / announcing from node" "${measured:-no ServiceL2Status}" \
          "R5 — MetalLB names the announcing node for both doors (ETP Local: a node with the Envoy pod)" ;;
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

# docker grpcurl on kind-eg (no Go cache). Callers capture $?; do not swallow it.
grpc_docker() { # extra args... -- method
  docker run --rm --network kind-eg fullstorydev/grpcurl:latest "$@" 2>&1
}
grpc_docker_tls() {
  docker run --rm --network kind-eg \
    -v "$PWD/$CA:/ca.crt:ro" fullstorydev/grpcurl:latest "$@" 2>&1
}
grpc_docker_probe() {
  docker run --rm --network kind-eg \
    -v "$PWD/demos/52-eg-poc2-metallb/probe:/probe:ro" \
    fullstorydev/grpcurl:latest "$@" 2>&1
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
list_rc=$?
if printf '%s' "$list_out" | payload_ok list v1 "$list_rc" >/dev/null; then
  row ok "gRPC ListOrders v1" "version=v1" "R10 — service default → grpc-v1"
else
  row fail "gRPC ListOrders v1" "$(printf '%s' "$list_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — service default → grpc-v1"
fi

# 14. GetOrder v2 (routing by method) — a stub {"version":"v2"} without served_by is FAIL
get_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  -d '{"id":2}' "${GRPC_ADDR}:80" shop.v1.Orders/GetOrder)
get_rc=$?
if printf '%s' "$get_out" | payload_ok get v2 "$get_rc" >/dev/null; then
  row ok "gRPC GetOrder v2" "version=v2" "R10 — method match → grpc-v2"
else
  row fail "gRPC GetOrder v2" "$(printf '%s' "$get_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — method match → grpc-v2"
fi

# 15. x-version v2 (routing by metadata)
hdr_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  -H 'x-version: v2' "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders)
hdr_rc=$?
if printf '%s' "$hdr_out" | payload_ok list v2 "$hdr_rc" >/dev/null; then
  row ok "gRPC ListOrders x-version v2" "version=v2" "R10 — metadata match → grpc-v2"
else
  row fail "gRPC ListOrders x-version v2" "$(printf '%s' "$hdr_out" | tr '\n' ' ' | head -c 80)" \
    "R10 — metadata match → grpc-v2"
fi

# 16. WatchOrders 5 events — objects with an `order` key, and the stream must succeed
watch_out=$(grpc_docker -plaintext -max-time 10 -authority "$GRPC_HOST" \
  -d '{"count":5,"interval_ms":200}' "${GRPC_ADDR}:80" shop.v1.Orders/WatchOrders)
watch_rc=$?
watch_n=$(printf '%s\n' "$watch_out" | python3 -c '
import json, sys
n = 0
dec = json.JSONDecoder()
s = sys.stdin.read()
i = 0
while i < len(s):
    while i < len(s) and s[i].isspace():
        i += 1
    if i >= len(s):
        break
    obj, j = dec.raw_decode(s, i)
    if isinstance(obj, dict) and "order" in obj:
        n += 1
    i = j
print(n)
' 2>/dev/null || echo 0)
if [ "$watch_rc" -eq 0 ] && [ "$watch_n" -eq 5 ]; then
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
  tls_rc=$?
  if printf '%s' "$tls_out" | payload_ok list v1 "$tls_rc" >/dev/null; then
    row ok "gRPC TLS ListOrders" "version=v1" "R10 — TLS ListOrders against the lab root"
  else
    row fail "gRPC TLS ListOrders" "$(printf '%s' "$tls_out" | tr '\n' ' ' | head -c 80)" \
      "R10 — TLS ListOrders against the lab root"
  fi
fi

echo
echo "demo 52 check: $fails FAIL"
exit "$fails"
