#!/usr/bin/env bash
# apply.sh — land demo 52 on eg-poc2: MetalLB (class-only, L2), two Gateways
# (HTTP isolated from gRPC), shop-db + shopapi + grpcdemo, the routes, L2
# proof, the gRPC test matrix from the Mac, a headless-Chrome screenshot.
# Idempotent. docker build is allowed for grpcdemo:local only.
#
#   demos/52-eg-poc2-metallb/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env
export RECORD_STRICT=1
HERE=demos/52-eg-poc2-metallb
TRANSCRIPT=$HERE/output/transcript.txt
CTX=kind-eg-poc2
CLUSTER=eg-poc2
CA=.tmp/eg-poc2-root-ca.crt
HTTP_ADDR=172.19.255.150
GRPC_ADDR=172.19.255.151
HTTP_HOST=api.eg-poc2.poc.local
GRPC_HOST=grpc.eg-poc2.poc.local
METALLB_CHART=${METALLB_VERSION#v}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '\n### %s — demo 52 apply\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

need_kind_load() { # needle — 0 if any node is missing the image
  local needle=$1 node
  for node in $(kind get nodes --name "$CLUSTER"); do
    if ! docker exec "$node" crictl images 2>/dev/null | grep -q "$needle"; then
      return 0
    fi
  done
  return 1
}

wait_envoy_deploy() { # gateway-name
  local gw=$1 i
  for i in $(seq 1 36); do
    if kubectl --context "$CTX" -n envoy-gateway-system get deploy \
         -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
         -o name 2>/dev/null | grep -q .; then
      kubectl --context "$CTX" -n envoy-gateway-system wait deploy \
        -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
        --for=condition=Available --timeout=180s
      return 0
    fi
    sleep 5
  done
  echo "apply.sh: no Envoy Deployment for $gw on $CTX after 180s" >&2
  kubectl --context "$CTX" -n envoy-gateway-system get deploy,svc >&2 || true
  return 1
}

wait_route() { # kind name
  local kind=$1 name=$2 i json
  for i in $(seq 1 24); do
    json=$(kubectl --context "$CTX" -n shop get "$kind" "$name" -o json 2>/dev/null || true)
    if printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
parents=d.get("status",{}).get("parents") or []
if not parents: sys.exit(1)
for p in parents:
    cond={c["type"]:c["status"] for c in p.get("conditions") or []}
    if cond.get("Accepted")!="True" or cond.get("ResolvedRefs")!="True":
        sys.exit(1)
' 2>/dev/null; then
      echo "$CTX $kind/$name: all parents Accepted+ResolvedRefs"
      return 0
    fi
    sleep 5
  done
  echo "apply.sh: $CTX $kind/$name NOT ready after 120s" >&2
  kubectl --context "$CTX" -n shop get "$kind" "$name" -o yaml >&2 || true
  return 1
}

# ---- 0. preflight ----
echo "== 0. preflight"
if [ ! -f "$CA" ]; then
  echo "apply.sh: $CA missing — run scripts/eg-up.sh eg-poc2 (issue #60: never commit a root)" >&2
  exit 1
fi
rec kubectl --context "$CTX" get --raw /readyz
gc=$(kubectl --context "$CTX" get gatewayclass eg \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
if [ "$gc" != True ]; then
  echo "apply.sh: GatewayClass eg is not Accepted (got ${gc:-absent}) — run scripts/eg-up.sh eg-poc2" >&2
  exit 1
fi
iss=$(kubectl --context "$CTX" get clusterissuer eg-ca-issuer \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$iss" != True ]; then
  echo "apply.sh: ClusterIssuer eg-ca-issuer is not Ready (got ${iss:-absent}) — run scripts/eg-up.sh eg-poc2" >&2
  exit 1
fi
echo "preflight: context $CTX reachable, GatewayClass eg Accepted, ClusterIssuer Ready, $CA present"

# ---- 1. WHAT WE DID IN DOCKER ----
echo "== 1. WHAT WE DID IN DOCKER"
docker_lab() {
  echo "---- kind-eg IPv4 (IPv6 IPRange prints invalid Prefix; skip that block) ----"
  docker network inspect kind-eg | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for net in doc:
    for c in (net.get("IPAM") or {}).get("Config") or []:
        subnet = c.get("Subnet") or ""
        if ":" in subnet:
            continue
        print("Subnet=%s IPRange=%s Gateway=%s" % (
            subnet, c.get("IPRange") or "", c.get("Gateway") or ""))
'
  echo "---- eg-poc2 nodes on kind-eg (IPv4 + MAC) ----"
  docker ps --filter name=eg-poc2 --format '{{.Names}} {{.Status}}'
  for node in $(kind get nodes --name "$CLUSTER"); do
    printf '%s ' "$node"
    docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}} {{(index .NetworkSettings.Networks "kind-eg").MacAddress}}' "$node"
  done
  echo "---- kubectl get nodes -o wide ----"
  kubectl --context "$CTX" get nodes -o wide
  echo "---- stock networking: kube-proxy mode + kindnet DS ----"
  kubectl --context "$CTX" -n kube-system get cm kube-proxy -o yaml | grep -E '^[[:space:]]*mode:'
  kubectl --context "$CTX" -n kube-system get ds kindnet kube-proxy
}
export -f docker_lab
export CTX CLUSTER
rec bash -c docker_lab
unset -f docker_lab

# ---- 2. MetalLB (phase-0 recipe, pinned) ----
echo "== 2. MetalLB $METALLB_CHART (class metallb.io/metallb, L2, no FRR)"
rec helm repo add metallb https://metallb.github.io/metallb --force-update
rec helm upgrade --install metallb metallb/metallb \
  --version "$METALLB_CHART" -n metallb-system --create-namespace \
  --kube-context "$CTX" \
  --set loadBalancerClass=metallb.io/metallb \
  --set speaker.frr.enabled=false \
  --set frrk8s.enabled=false
rec kubectl --context "$CTX" -n metallb-system wait deploy \
  -l app.kubernetes.io/component=controller --for=condition=Available --timeout=180s
rec kubectl --context "$CTX" -n metallb-system rollout status ds \
  -l app.kubernetes.io/component=speaker --timeout=180s
rec bash -c "kubectl --context $CTX -n metallb-system get deploy,ds -o yaml | grep -E 'lb-class|loadBalancerClass'"
rec kubectl --context "$CTX" apply -f "$HERE/10-metallb-pool.yaml"

# ---- 3. namespace, ConfigMap, kind load ----
echo "== 3. namespace shop, ConfigMap eg-cluster, kind load"
rec kubectl --context "$CTX" apply -f "$HERE/00-namespace.yaml"
rec bash -c "kubectl --context $CTX apply -f -" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: eg-cluster
  namespace: shop
data:
  name: $CLUSTER
EOF
if need_kind_load shopapi; then
  rec kind load docker-image shopapi:local --name "$CLUSTER"
else
  echo "skip kind load shopapi:local — crictl images already shows it on $CLUSTER"
fi
if need_kind_load grpcdemo; then
  rec env CLUSTER="$CLUSTER" "$HERE/grpcdemo/build.sh"
else
  echo "skip build/load grpcdemo:local — crictl images already shows it on $CLUSTER"
fi

# ---- 4. certificate ----
echo "== 4. certificate eg-poc2-tls (Ready ≤ 90s)"
rec kubectl --context "$CTX" apply -f "$HERE/20-certificate.yaml"
rec kubectl --context "$CTX" -n shop wait certificate/eg-poc2-tls --for=condition=Ready --timeout=90s
print_leaf() {
  local pem
  pem=$(kubectl --context "$CTX" -n shop get secret eg-poc2-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d)
  echo "$pem" | openssl x509 -noout -subject -ext subjectAltName -enddate
  echo -n "sha256="
  echo "$pem" | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2
}
export -f print_leaf
export CTX
rec bash -c print_leaf
unset -f print_leaf

# ---- 5. EnvoyProxies then Gateways ----
echo "== 5. EnvoyProxies + Gateways (Programmed ≤ 180s; Envoy Deployment Available)"
export -f wait_envoy_deploy
export CTX
rec kubectl --context "$CTX" apply -f "$HERE/30-gateways.yaml"
rec kubectl --context "$CTX" -n shop wait --for=condition=Programmed gateway/http-gw --timeout=180s
rec kubectl --context "$CTX" -n shop wait --for=condition=Programmed gateway/grpc-gw --timeout=180s
rec bash -c 'wait_envoy_deploy http-gw'
rec bash -c 'wait_envoy_deploy grpc-gw'

# ---- 6. app + routes ----
echo "== 6. shop-db + shopapi + grpcdemo + routes (Accepted + ResolvedRefs)"
export -f wait_route
rec kubectl --context "$CTX" apply -f "$HERE/45-shop-db.yaml"
rec kubectl --context "$CTX" -n shop rollout status deploy/shop-db --timeout=180s
rec kubectl --context "$CTX" apply -f "$HERE/40-app.yaml"
rec kubectl --context "$CTX" -n shop wait deploy/shopapi --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" apply -f "$HERE/41-grpcdemo.yaml"
rec kubectl --context "$CTX" -n shop wait deploy/grpcdemo-v1 --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" -n shop wait deploy/grpcdemo-v2 --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" apply -f "$HERE/50-routes.yaml"
rec bash -c 'wait_route httproute shop-api'
rec bash -c 'wait_route grpcroute orders'

# ---- 7. L2 PROOF (MetalLB answers ARP; the address is NOT on eth0) ----
echo "== 7. L2 PROOF (arping → MAC → node; ServiceL2Status or speaker log; not on eth0)"
l2_proof() { # ip
  local ip=$1 out mac node crd logs
  echo "---- arping -b -c 3 $ip ----"
  out=$(docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -b -c 3 -I eth0 "$ip" 2>&1 || true)
  printf '%s\n' "$out"
  mac=$(printf '%s\n' "$out" | awk '/Unicast reply/{gsub(/[\[\]]/,"",$5); print $5; exit}')
  node="?"
  if [ -n "$mac" ]; then
    for n in $(kind get nodes --name "$CLUSTER"); do
      nmac=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").MacAddress}}' "$n")
      nmac_lc=$(printf '%s' "$nmac" | tr '[:upper:]' '[:lower:]')
      mac_lc=$(printf '%s' "$mac" | tr '[:upper:]' '[:lower:]')
      if [ "$nmac_lc" = "$mac_lc" ]; then
        node=$n
        break
      fi
    done
  fi
  echo "MAC $mac → node $node"
  echo "---- ServiceL2Status / speaker (whole log, --tail=-1 --prefix) ----"
  crd=$(kubectl --context "$CTX" get crd servicel2statuses.metallb.io -o name 2>&1) || true
  if printf '%s' "$crd" | grep -q servicel2statuses.metallb.io; then
    echo "CRD servicel2statuses.metallb.io: present"
    # MetalLB keeps these in its own namespace (measured: metallb-system), named l2-xxxxx,
    # with the Service and the announcing node in .status
    kubectl --context "$CTX" -n metallb-system get servicel2status \
      -o custom-columns='NAME:.metadata.name,SERVICE:.status.serviceName,NAMESPACE:.status.serviceNamespace,NODE:.status.node' 2>&1 || true
  else
    echo "CRD servicel2statuses.metallb.io: absent — speaker announcing-from-node log"
    logs=$(kubectl --context "$CTX" -n metallb-system logs \
      -l app.kubernetes.io/component=speaker --tail=-1 --prefix --timestamps 2>/dev/null \
      | grep -F "$ip" || true)
    printf '%s\n' "$logs"
    if printf '%s\n' "$logs" | grep -qF "announcing from node"; then
      echo "announcing from node for $ip: present"
    else
      echo "announcing from node for $ip: ABSENT"
    fi
  fi
  echo "---- Service events IPAllocated / announcing from node ($ip) ----"
  kubectl --context "$CTX" -n envoy-gateway-system get events --sort-by=.lastTimestamp 2>/dev/null \
    | grep -E "IPAllocated|announcing from node" || true
  echo "---- docker exec ${node} ip -4 addr show eth0 (MetalLB does NOT add $ip) ----"
  if [ "$node" != "?" ]; then
    docker exec "$node" ip -4 addr show eth0
    if docker exec "$node" ip -4 addr show eth0 | grep -Eq "inet ${ip//./\\.}/"; then
      echo "$ip IS on $node eth0 (unexpected for MetalLB)"
    else
      echo "$ip NOT on $node eth0 — MetalLB answers ARP for it, kube-proxy delivers it"
    fi
  fi
}
export -f l2_proof
export CTX CLUSTER
rec bash -c 'l2_proof "$1"' bash "$HTTP_ADDR"
rec bash -c 'l2_proof "$1"' bash "$GRPC_ADDR"
unset -f l2_proof

# ---- 8. FROM THE MACBOOK ----
echo "== 8. FROM THE MACBOOK"
mac_route() {
  local line
  line=$(netstat -rn | grep 172.19 || true)
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
  else
    echo "no 172.19 route on this Mac — the clients below will fail until:"
    echo "  sudo route -n add -net 172.19.0.0/16 192.168.64.2"
  fi
}
export -f mac_route
rec bash -c mac_route
unset -f mac_route

mac_http() {
  local rc=0 hdr code served
  hdr=$(curl -s --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
    -D - -o /dev/null "http://${HTTP_HOST}/healthz" \
    --connect-timeout 5 --max-time 10) || rc=$?
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  served=$(printf '%s' "$hdr" | awk '
    tolower($0) ~ /^[[:space:]]*x-served-by:[[:space:]]*/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }')
  echo "http://${HTTP_HOST}/healthz @ ${HTTP_ADDR}:80 → ${code} X-Served-By=${served:--} curl_rc=$rc"
}
mac_https() {
  local rc=0 hdr code served
  hdr=$(curl -s --resolve "${HTTP_HOST}:443:${HTTP_ADDR}" --cacert "$CA" \
    -D - -o /dev/null "https://${HTTP_HOST}/healthz" \
    --connect-timeout 5 --max-time 10) || rc=$?
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  served=$(printf '%s' "$hdr" | awk '
    tolower($0) ~ /^[[:space:]]*x-served-by:[[:space:]]*/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }')
  echo "https://${HTTP_HOST}/healthz @ ${HTTP_ADDR}:443 → ${code} X-Served-By=${served:--} curl_rc=$rc"
}
mac_orders() {
  local rc=0 hdr code served bodyf
  bodyf=$(mktemp)
  hdr=$(curl -s --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
    -D - -o "$bodyf" -H "Accept: application/json" \
    "http://${HTTP_HOST}/orders" --connect-timeout 5 --max-time 10) || rc=$?
  hdr=$(printf '%s' "$hdr" | tr -d '\r')
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  served=$(printf '%s' "$hdr" | awk '
    tolower($0) ~ /^[[:space:]]*x-served-by:[[:space:]]*/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }')
  echo "http://${HTTP_HOST}/orders @ ${HTTP_ADDR}:80 → ${code} X-Served-By=${served:--} curl_rc=$rc body_head:"
  head -c 200 "$bodyf"; echo
  rm -f "$bodyf"
}
export -f mac_http mac_https mac_orders
export HTTP_HOST HTTP_ADDR GRPC_HOST GRPC_ADDR CA
rec bash -c mac_http
rec bash -c mac_https
rec bash -c mac_orders
unset -f mac_http mac_https mac_orders

echo "== 8b. gRPC test matrix from the Mac (grpcurl@v1.9.4)"
grpc_matrix() {
  local GRPCURL=(go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4)
  local tbl rc out n bogus verdict matrix_failures=0
  tbl=$(mktemp)

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

  row() { # id expected observed pass|fail
    if [ "$4" = FAIL ]; then matrix_failures=$((matrix_failures + 1)); fi
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$tbl"
    echo "T $1 expected=$2 observed=$3 $4"
  }
  observed() { # collapse to one line
    printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | cut -c1-80
  }

  echo "-- T1 list + describe shop.v1.Orders"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" list 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T1_list_rc=$rc"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" describe shop.v1.Orders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T1_describe_rc=$rc"
  if printf '%s' "$out" | grep -q ListOrders \
     && printf '%s' "$out" | grep -q GetOrder \
     && printf '%s' "$out" | grep -q WatchOrders \
     && printf '%s' "$out" | grep -q SlowOrder; then
    row T1 "four RPCs via reflection" "ListOrders GetOrder WatchOrders SlowOrder" PASS
  else
    row T1 "four RPCs via reflection" "$(observed "$out")" FAIL
  fi

  echo "-- T2 ListOrders h2c → v1, three orders, served_by grpcdemo-v1-"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T2_rc=$rc"
  if printf '%s' "$out" | payload_ok list v1 "$rc" >/dev/null; then
    row T2 "3 orders version v1 served_by grpcdemo-v1-" "v1 + three rows" PASS
  else
    row T2 "3 orders version v1 served_by grpcdemo-v1-" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T3 ListOrders TLS :443 --cacert (never -insecure)"
  rc=0
  out=$("${GRPCURL[@]}" -cacert "$CA" -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:443" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T3_rc=$rc"
  if printf '%s' "$out" | payload_ok list v1 "$rc" >/dev/null; then
    row T3 "TLS ListOrders v1" "v1 rc=0" PASS
  else
    row T3 "TLS ListOrders v1" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T4 GetOrder id=2 → version v2 (routing by method)"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -d '{"id":2}' "${GRPC_ADDR}:80" shop.v1.Orders/GetOrder 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T4_rc=$rc"
  if printf '%s' "$out" | payload_ok get v2 "$rc" >/dev/null; then
    row T4 "GetOrder id=2 version v2" "v2" PASS
  else
    row T4 "GetOrder id=2 version v2" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T5 ListOrders -H x-version:v2 → v2; without header → v1"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -H 'x-version: v2' "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T5_v2_rc=$rc"
  rc=0
  out2=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  printf '%s\n' "$out2"
  echo "T5_v1_rc=$rc"
  if printf '%s' "$out" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"v2"' \
     && printf '%s' "$out2" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"v1"'; then
    row T5 "x-version v2 then default v1" "v2 then v1" PASS
  else
    row T5 "x-version v2 then default v1" "header=$(observed "$out") nohdr=$(observed "$out2")" FAIL
  fi

  echo "-- T6 WatchOrders count=5 interval_ms=200 → five events"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -d '{"count":5,"interval_ms":200}' \
    "${GRPC_ADDR}:80" shop.v1.Orders/WatchOrders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T6_rc=$rc"
  n=$(printf '%s\n' "$out" | python3 -c '
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
  if [ "$rc" -eq 0 ] && [ "$n" -eq 5 ]; then
    row T6 "5 streamed events" "events=$n" PASS
  else
    row T6 "5 streamed events" "events=$n rc=$rc" FAIL
  fi

  echo "-- T7 GetOrder id=99 → Code: NotFound"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -d '{"id":99}' "${GRPC_ADDR}:80" shop.v1.Orders/GetOrder 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T7_rc=$rc"
  if printf '%s' "$out" | grep -Eq 'Code:[[:space:]]*NotFound'; then
    row T7 "Code: NotFound" "NotFound" PASS
  else
    row T7 "Code: NotFound" "$(observed "$out") rc=$rc" FAIL
  fi

  # reflection-driven grpcurl validates the method locally, so an unimplemented method must be described to it to be sent at all.
  echo "-- T8a shop.v1.Orders/NoSuchMethod (descriptor) → Code: Unimplemented + unknown method"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext \
    -import-path demos/52-eg-poc2-metallb/probe -proto probe.proto \
    -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" shop.v1.Orders/NoSuchMethod 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T8a_rc=$rc"
  if printf '%s' "$out" | grep -Eq 'Code:[[:space:]]*Unimplemented' \
     && printf '%s' "$out" | grep -q 'unknown method NoSuchMethod for service shop.v1.Orders'; then
    row T8a "Code: Unimplemented + unknown method" "Unimplemented unknown method" PASS
  else
    row T8a "Code: Unimplemented + unknown method" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T8b shop.v1.Nope/Do (descriptor) → Code: Unimplemented + empty Message"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext \
    -import-path demos/52-eg-poc2-metallb/probe -proto nope.proto \
    -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" shop.v1.Nope/Do 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T8b_rc=$rc"
  if printf '%s' "$out" | grep -Eq 'Code:[[:space:]]*Unimplemented' \
     && printf '%s\n' "$out" | grep -Eq 'Message:[[:space:]]*$'; then
    row T8b "Code: Unimplemented + empty Message" "Unimplemented empty Message" PASS
  else
    row T8b "Code: Unimplemented + empty Message" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T9 SlowOrder delay_ms=3000 -max-time 1 → Code: DeadlineExceeded"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -max-time 1 -d '{"delay_ms":3000}' \
    "${GRPC_ADDR}:80" shop.v1.Orders/SlowOrder 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T9_rc=$rc"
  if printf '%s' "$out" | grep -Eq 'Code:[[:space:]]*DeadlineExceeded'; then
    row T9 "Code: DeadlineExceeded" "DeadlineExceeded" PASS
  else
    row T9 "Code: DeadlineExceeded" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T10 -v ListOrders → x-served-by / x-version metadata"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -v "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T10_rc=$rc"
  if printf '%s' "$out" | grep -qi 'x-served-by' && printf '%s' "$out" | grep -qi 'x-version'; then
    row T10 "metadata x-served-by + x-version" "both present" PASS
  else
    row T10 "metadata x-served-by + x-version" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T11 TLS with a bogus CA (not -insecure) → tls: failed to verify certificate"
  bogus=$(mktemp)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$bogus.key" -out "$bogus" -subj /CN=bogus -days 1 >/dev/null 2>&1
  rc=0
  out=$("${GRPCURL[@]}" -cacert "$bogus" -authority "$GRPC_HOST" -max-time 10 \
    "${GRPC_ADDR}:443" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T11_rc=$rc"
  rm -f "$bogus" "$bogus.key"
  # rc≠0 alone is not the proof: a dead door's dial timeout is rc=1 too (measured
  # against an unallocated pool address). The verification error is.
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'failed to verify certificate'; then
    row T11 "TLS fails with bogus CA" "$(observed "$out") rc=$rc" PASS
  else
    row T11 "TLS fails with bogus CA" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T12 isolation: grpc authority at HTTP door; api host at gRPC door"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    "${HTTP_ADDR}:80" grpc.health.v1.Health/Check 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "isolation_grpcurl_rc=$rc"
  iso_grpc=$rc
  rc=0
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --resolve "${HTTP_HOST}:80:${GRPC_ADDR}" \
    "http://${HTTP_HOST}/healthz" --connect-timeout 5 --max-time 10) || rc=$?
  echo "isolation_http_code=${code} curl_rc=$rc"
  if [ "$iso_grpc" -ne 0 ] && [ "$code" = 404 ]; then
    row T12 "grpc@.150 not served; curl@.151 → 404" "grpcurl_rc=$iso_grpc http=$code" PASS
  else
    row T12 "grpc@.150 not served; curl@.151 → 404" "grpcurl_rc=$iso_grpc http=$code" FAIL
  fi

  echo "-- T13 Health/Check \"\" and shop.v1.Orders → SERVING"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -d '{"service":""}' "${GRPC_ADDR}:80" grpc.health.v1.Health/Check 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T13_empty_rc=$rc"
  rc=0
  out2=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    -d '{"service":"shop.v1.Orders"}' "${GRPC_ADDR}:80" grpc.health.v1.Health/Check 2>&1) || rc=$?
  printf '%s\n' "$out2"
  echo "T13_svc_rc=$rc"
  if printf '%s' "$out" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"SERVING"' \
     && printf '%s' "$out2" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"SERVING"'; then
    row T13 '{"status": "SERVING"} for "" and shop.v1.Orders' "SERVING SERVING" PASS
  else
    row T13 '{"status": "SERVING"} for "" and shop.v1.Orders' "$(observed "$out") $(observed "$out2")" FAIL
  fi

  echo
  echo "==== gRPC matrix summary ===="
  printf '%-4s %-48s %-28s %s\n' TEST EXPECTED OBSERVED RESULT
  while IFS=$'\t' read -r id exp obs ver; do
    printf '%-4s %-48s %-28s %s\n' "$id" "$exp" "$obs" "$ver"
  done <"$tbl"
  echo "gRPC matrix: $matrix_failures FAIL"
  rm -f "$tbl"
  return "$matrix_failures"
}
export -f grpc_matrix
export HTTP_HOST HTTP_ADDR GRPC_HOST GRPC_ADDR CA
matrix_fails=0
rec bash -c grpc_matrix || matrix_fails=$?
unset -f grpc_matrix

# ---- 9. THE BROWSER ----
echo "== 9. THE BROWSER (headless Chrome, no /etc/hosts)"
browser_shot() {
  if [ ! -x "$CHROME" ]; then
    echo "Chrome is absent at $CHROME — skipping screenshot"
    return 0
  fi
  local shot="$PWD/$HERE/output/browser.png" profile rc=0 pid i waited="" size1 size2
  profile=$(mktemp -d)
  rm -f "$shot"
  echo "$CHROME --headless=new --disable-gpu --no-first-run --window-size=1000,500 --user-data-dir=<tmp> --host-resolver-rules=\"MAP ${HTTP_HOST} ${HTTP_ADDR}\" --screenshot=$shot http://${HTTP_HOST}/orders"
  "$CHROME" --headless=new --disable-gpu --no-first-run --window-size=1000,500 \
    --user-data-dir="$profile" \
    --host-resolver-rules="MAP ${HTTP_HOST} ${HTTP_ADDR}" \
    --screenshot="$shot" \
    "http://${HTTP_HOST}/orders" >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 300); do
    if [ -s "$shot" ]; then
      size1=$(stat -f %z "$shot" 2>/dev/null || stat -c %s "$shot")
      sleep 0.2
      size2=$(stat -f %z "$shot" 2>/dev/null || stat -c %s "$shot")
      if [ "$size1" = "$size2" ]; then
        waited=$(awk -v n="$i" 'BEGIN{printf "%.1f", (n+1)*0.2}')
        break
      fi
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || rc=$?
  rm -rf "$profile"
  if [ -s "$shot" ]; then
    echo "screenshot written after ${waited:-<0.2} s; chrome_rc=$rc"
    file "$HERE/output/browser.png"
  else
    echo "no screenshot written within 60 s"
  fi
}
export -f browser_shot
export CHROME HERE HTTP_HOST HTTP_ADDR
rec bash -c browser_shot
unset -f browser_shot

# ---- 10. hosts block ----
echo "== 10. hosts-entries.sh (operator adds this to /etc/hosts; checks use --resolve)"
rec "$HERE/hosts-entries.sh"

# ---- 11. final table ----
echo "== 11. final table"
final_table() {
  python3 - <<'PY'
import json, os, re, subprocess

CTX = "kind-eg-poc2"
CA = ".tmp/eg-poc2-root-ca.crt"
HTTP_ADDR = "172.19.255.150"
GRPC_ADDR = "172.19.255.151"
HTTP_HOST = "api.eg-poc2.poc.local"
GRPC_HOST = "grpc.eg-poc2.poc.local"

def run(args):
    p = subprocess.run(args, capture_output=True, text=True)
    return p.stdout.strip(), p.returncode

net = json.loads(subprocess.check_output(["docker", "network", "inspect", "kind-eg"]))[0]
mac_node = {}
for c in net.get("Containers", {}).values():
    mac_node[(c.get("MacAddress") or "").lower()] = c.get("Name", "?")

def arping(ip):
    p = subprocess.run(
        ["docker", "run", "--rm", "--network", "kind-eg", "--cap-add", "NET_RAW",
         "busybox:1.36", "arping", "-b", "-c", "3", "-I", "eth0", ip],
        capture_output=True, text=True)
    macs = []
    for line in (p.stdout + p.stderr).splitlines():
        if "Unicast reply" in line and "[" in line:
            mac = line.split("[")[1].split("]")[0].lower()
            macs.append(mac)
    if not macs:
        return "-", "0"
    node = mac_node.get(macs[0], macs[0])
    return node, f"{len(macs)}/3"

def https_or_http(host, addr, tls):
    if tls:
        args = ["curl", "-s", "--resolve", f"{host}:443:{addr}",
                "--cacert", CA, f"https://{host}/healthz",
                "-D", "-", "-o", "/dev/null",
                "--connect-timeout", "5", "--max-time", "10"]
    else:
        args = ["curl", "-s", "--resolve", f"{host}:80:{addr}",
                f"http://{host}/healthz",
                "-D", "-", "-o", "/dev/null",
                "--connect-timeout", "5", "--max-time", "10"]
    p = subprocess.run(args, capture_output=True, text=True)
    hdr = p.stdout.replace("\r", "")
    code = "000"
    served = "-"
    for line in hdr.splitlines():
        if line.startswith("HTTP"):
            parts = line.split()
            if len(parts) > 1:
                code = parts[1]
        if line.lower().startswith("x-served-by:"):
            served = line.split(":", 1)[1].strip()
    return f"{code}/{served}"

def grpc(auth, addr, tls):
    if tls:
        args = ["go", "run", "github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4",
                "-cacert", CA, "-authority", auth,
                f"{addr}:443", "grpc.health.v1.Health/Check"]
    else:
        args = ["go", "run", "github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4",
                "-plaintext", "-authority", auth,
                f"{addr}:80", "grpc.health.v1.Health/Check"]
    p = subprocess.run(args, capture_output=True, text=True)
    out = p.stdout + p.stderr
    return "SERVING" if re.search(r'"status"\s*:\s*"SERVING"', out) else "FAIL"

print(f"{'DOOR':<10} {'ADDRESS':<16} {'PROG':<6} {'CLASS':<22} {'ANNOUNCED_BY':<22} {'HTTP_or_GRPC'}")
for gw, addr, kind in (("http-gw", HTTP_ADDR, "http"), ("grpc-gw", GRPC_ADDR, "grpc")):
    prog, _ = run(["kubectl", "--context", CTX, "-n", "shop", "get", "gateway", gw,
                   "-o", "jsonpath={.status.conditions[?(@.type==\"Programmed\")].status}"])
    svc = subprocess.run(
        ["kubectl", "--context", CTX, "-n", "envoy-gateway-system", "get", "svc",
         "-l", f"gateway.envoyproxy.io/owning-gateway-name={gw}", "-o", "json"],
        capture_output=True, text=True)
    klass = "?"
    try:
        items = json.loads(svc.stdout).get("items") or []
        if items:
            klass = (items[0].get("spec") or {}).get("loadBalancerClass") or "-"
    except Exception:
        klass = "?"
    node, _ = arping(addr)
    if kind == "http":
        cell = "HTTP " + https_or_http(HTTP_HOST, addr, False)
    else:
        cell = "GRPC " + grpc(GRPC_HOST, addr, False)
    print(f"{gw:<10} {addr:<16} {prog or '?':<6} {klass:<22} {node:<22} {cell}")
PY
}
export -f final_table
rec bash -c final_table
unset -f final_table wait_envoy_deploy wait_route

echo "demo 52 apply: done"
if [ "${matrix_fails:-0}" -ne 0 ]; then
  echo "demo 52 apply: gRPC matrix had $matrix_fails FAIL"
  exit 1
fi
