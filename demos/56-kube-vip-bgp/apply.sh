#!/usr/bin/env bash
# apply.sh — migrate eg-poc1 from L2 kube-vip (demo 54) to BGP: election
# first (10a), then active-active (10b); Envoy Gateway doors on the
# routed block; the gRPC matrix from client0. Idempotent. No docker
# build (gotcha #118); kind load of grpcdemo:local is allowed.
# Demo 54's doors (.100/.101) stop answering once 10b is applied.
#
#   demos/56-kube-vip-bgp/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
HERE=demos/56-kube-vip-bgp
TRANSCRIPT=$HERE/output/transcript.txt
CTX=kind-eg-poc1
CLUSTER=eg-poc1
CA=.tmp/eg-poc1-root-ca.crt
HTTP_ADDR=10.98.0.10
GRPC_ADDR=10.98.0.11
L2_HTTP=172.19.255.100
L2_GRPC=172.19.255.101
HTTP_HOST=api.eg-poc1.poc.local
GRPC_HOST=grpc.eg-poc1.poc.local
CLIENT=bgp-fabric-client0-1
FABRIC=demos/46-bgp-fabric/fabric
PROJECT=bgp-fabric
PROBE=demos/52-eg-poc2-metallb/probe
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '\n### %s — demo 56 apply\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TRANSCRIPT"
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
echo "== 0. preflight (fabric + kind-eg-poc1 + demo 54; no docker build)"
if [ ! -f "$CA" ]; then
  echo "apply.sh: $CA missing — run scripts/eg-up.sh eg-poc1 (issue #60: never commit a root)" >&2
  exit 1
fi
ps_out=$(docker compose -p "$PROJECT" ps --format '{{.Name}} {{.Service}} {{.State}} {{.Health}}' 2>&1) || ps_out=""
leaf_ok=1
for svc in leaf1 leaf2; do
  if ! printf '%s\n' "$ps_out" | grep -Eq "${PROJECT}-${svc}-[0-9]+ ${svc} running healthy"; then
    leaf_ok=0
  fi
done
ip11=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "${PROJECT}-leaf1-1" 2>/dev/null || true)
ip12=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "${PROJECT}-leaf2-1" 2>/dev/null || true)
if [ "$leaf_ok" -ne 1 ] || [ "$ip11" != 172.19.254.11 ] || [ "$ip12" != 172.19.254.12 ]; then
  echo "apply.sh: fabric not up on kind-eg (leaf1/leaf2 healthy at 172.19.254.11/.12). run demos/46-bgp-fabric/apply.sh" >&2
  exit 1
fi
rec kubectl --context "$CTX" get --raw /readyz
ready=$(kubectl --context "$CTX" get --raw /readyz 2>/dev/null || true)
if [ "$ready" != ok ]; then
  echo "apply.sh: context $CTX not reachable (got ${ready:-absent})" >&2
  exit 1
fi
for pair in "http-gw:$L2_HTTP" "grpc-gw:$L2_GRPC"; do
  gw=${pair%%:*}; want=${pair#*:}
  prog=$(kubectl --context "$CTX" -n shop get gateway "$gw" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  addr=$(kubectl --context "$CTX" -n shop get gateway "$gw" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [ "$prog" != True ] || [ "$addr" != "$want" ]; then
    echo "apply.sh: demo 54 not applied ($gw Programmed=${prog:-?} addr=${addr:-?} want=$want)" >&2
    exit 1
  fi
done
echo "preflight: fabric leaf1/leaf2 healthy at $ip11/$ip12; $CTX ready; demo 54 doors Programmed"

# ---- 1. BEFORE — L2 as demo 54 left it; SERVERS peers = 0 ----
echo "== 1. BEFORE — L2 as demo 54 left it"
before_state_rec() {
  echo "---- arping -b -c 3 $L2_HTTP ----"
  docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -b -c 3 -I eth0 "$L2_HTTP" 2>&1 || true
  echo "---- Mac curl $L2_HTTP (if 172.19 route exists) ----"
  if netstat -rn | grep -q '172\.19'; then
    local rc=0 hdr code
    hdr=$(curl -s --resolve "${HTTP_HOST}:80:${L2_HTTP}" \
      -D - -o /dev/null "http://${HTTP_HOST}/healthz" \
      --connect-timeout 5 --max-time 10) || rc=$?
    hdr=$(printf '%s' "$hdr" | tr -d '\r')
    code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
    echo "http://${HTTP_HOST}/healthz @ ${L2_HTTP}:80 → ${code} curl_rc=$rc"
  else
    echo "no 172.19 route on this Mac — L2 curl skipped"
  fi
  echo "---- leaves SERVERS peers ----"
  local leaf raw n
  for leaf in leaf1 leaf2; do
    echo "-- $leaf"
    raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
      exec -T "$leaf" vtysh -c 'show bgp summary json' 2>&1) || raw=""
    printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py
    n=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("FAIL"); raise SystemExit
peers = {}
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("peers"), dict):
            peers.update(o["peers"])
        for v in o.values():
            walk(v)
walk(data)
servers = [ip for ip, p in peers.items() if str((p or {}).get("remoteAs") or (p or {}).get("remoteAS") or "") == "65021"]
print("SERVERS_peers=%d" % len(servers))
')
    echo "$leaf $n"
  done
}
export -f before_state_rec
export L2_HTTP HTTP_HOST PROJECT FABRIC
rec bash -c before_state_rec
unset -f before_state_rec

# ---- 2. Switch kube-vip to BGP with election ON (10a) ----
echo "== 2. kube-vip BGP election ON (10a)"
rec kubectl --context "$CTX" apply -f "$HERE/10a-kube-vip-ds-bgp-election.yaml"
t0=$(date +%s)
rec kubectl --context "$CTX" -n kube-system rollout status ds/kube-vip-ds --timeout=180s
wait_established() { # seconds
  local budget=$1 i leaf raw ok
  for i in $(seq 1 "$budget"); do
    ok=1
    for leaf in leaf1 leaf2; do
      raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
        exec -T "$leaf" vtysh -c 'show bgp summary json' 2>&1) || raw=""
      n=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print(0); raise SystemExit
peers = {}
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("peers"), dict):
            peers.update(o["peers"])
        for v in o.values():
            walk(v)
walk(data)
n = 0
for ip, p in peers.items():
    asn = str((p or {}).get("remoteAs") or (p or {}).get("remoteAS") or "")
    st = (p or {}).get("state") or (p or {}).get("peerState") or (p or {}).get("bgpState") or ""
    if asn == "65021" and st == "Established":
        n += 1
print(n)
')
      if [ "${n:-0}" -lt 2 ]; then
        ok=0
      fi
    done
    if [ "$ok" -eq 1 ]; then
      echo "SERVERS Established on both leaves after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "apply.sh: SERVERS not Established on both leaves after ${budget}s" >&2
  return 1
}
export -f wait_established
export PROJECT FABRIC
rec bash -c 'wait_established 90'
t1=$(date +%s)
echo "rollout-to-Established: $((t1 - t0))s"
election_record() {
  echo "---- node IPs ----"
  kind get nodes --name "$CLUSTER"
  for n in $(kind get nodes --name "$CLUSTER"); do
    printf '%s ' "$n"
    docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "$n"
  done
  echo "---- leaf show bgp summary json ----"
  local leaf
  for leaf in leaf1 leaf2; do
    echo "-- $leaf"
    docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
      exec -T "$leaf" vtysh -c 'show bgp summary json'
  done
  echo "---- kube-vip DS logs (BGP lines; whole log, --tail=-1 --prefix) ----"
  kubectl --context "$CTX" -n kube-system logs -l app.kubernetes.io/name=kube-vip-ds \
    --tail=-1 --prefix --timestamps 2>/dev/null | grep -iE 'bgp|peer|65021|172\.19\.254' || true
}
export -f election_record
export CLUSTER PROJECT FABRIC CTX
rec bash -c election_record
unset -f wait_established election_record

# ---- 3. BGP doors with ETP Local FIRST + app + shopapi HA + routes ----
echo "== 3. BGP doors ETP Local (20a) + grpcdemo + shopapi HA + routes"
if need_kind_load grpcdemo; then
  rec kind load docker-image grpcdemo:local --name "$CLUSTER"
else
  echo "skip kind load grpcdemo:local — crictl images already shows it on $CLUSTER"
fi
export -f wait_envoy_deploy wait_route
export CTX
rec kubectl --context "$CTX" apply -f "$HERE/20a-gateways-bgp-etp-local.yaml"
rec kubectl --context "$CTX" -n shop wait --for=condition=Programmed gateway/bgp-http-gw --timeout=180s
rec kubectl --context "$CTX" -n shop wait --for=condition=Programmed gateway/bgp-grpc-gw --timeout=180s
rec bash -c 'wait_envoy_deploy bgp-http-gw'
rec bash -c 'wait_envoy_deploy bgp-grpc-gw'
rec kubectl --context "$CTX" -n envoy-gateway-system wait deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw \
  --for=jsonpath='{.status.readyReplicas}'=2 --timeout=180s
rec kubectl --context "$CTX" -n envoy-gateway-system wait deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=bgp-grpc-gw \
  --for=jsonpath='{.status.readyReplicas}'=2 --timeout=180s
rec kubectl --context "$CTX" apply -f "$HERE/40-grpcdemo.yaml"
rec kubectl --context "$CTX" -n shop wait deploy/grpcdemo-v1 --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" -n shop wait deploy/grpcdemo-v2 --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" apply -f "$HERE/41-shopapi-ha.yaml"
rec kubectl --context "$CTX" -n shop wait deploy/shopapi --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" apply -f "$HERE/50-routes-bgp.yaml"
rec bash -c 'wait_route httproute shop-api-bgp'
rec bash -c 'wait_route grpcroute orders-bgp'

# one of each on each node — FAIL the step if both replicas landed on one node
require_spread() {
  echo "---- envoy-gateway-system pods ----"
  kubectl --context "$CTX" -n envoy-gateway-system get pods -o wide
  echo "---- shopapi pods ----"
  kubectl --context "$CTX" -n shop get pods -l app=shopapi -o wide
  local gw nodes nuniq
  for gw in bgp-http-gw bgp-grpc-gw; do
    nodes=$(kubectl --context "$CTX" -n envoy-gateway-system get pods \
      -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
      -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>&1) || nodes=""
    nuniq=$(printf '%s\n' "$nodes" | awk 'NF && !seen[$0]++ {n++} END{print n+0}')
    echo "$gw nodes: $(printf '%s' "$nodes" | tr '\n' ' ') unique=$nuniq"
    if [ "$nuniq" -lt 2 ]; then
      echo "apply.sh: $gw Envoy replicas not spread (one per node required)" >&2
      return 1
    fi
  done
  nodes=$(kubectl --context "$CTX" -n shop get pods -l app=shopapi \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>&1) || nodes=""
  nuniq=$(printf '%s\n' "$nodes" | awk 'NF && !seen[$0]++ {n++} END{print n+0}')
  echo "shopapi nodes: $(printf '%s' "$nodes" | tr '\n' ' ') unique=$nuniq"
  if [ "$nuniq" -lt 2 ]; then
    echo "apply.sh: shopapi replicas not spread (one per node required)" >&2
    return 1
  fi
}
export -f require_spread
export CTX
rec bash -c require_spread
unset -f require_spread

doors_local() {
  echo "---- spine show ip bgp 10.98.0.10/32 (expect ONE path — the leader) ----"
  docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T spine vtysh -c 'show ip bgp 10.98.0.10/32'
  echo "---- spine show ip bgp 10.98.0.10/32 json path count ----"
  raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T spine vtysh -c 'show ip bgp 10.98.0.10/32 json' 2>&1) || raw=""
  printf '%s' "$raw" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("paths=FAIL"); raise SystemExit
def paths_of(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("paths"), list):
            return obj["paths"]
        for v in obj.values():
            found = paths_of(v)
            if found is not None:
                return found
    return None
found = paths_of(data)
print("paths=%s" % (len(found) if found is not None else "FAIL"))
if found:
    for p in found:
        nh = p.get("nexthop") or p.get("nexthops") or p.get("peer")
        print("path nexthop=%s" % nh)
'
  echo "---- leaves received-routes from each node ----"
  local n ip leaf
  for n in $(kind get nodes --name "$CLUSTER"); do
    ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "$n")
    for leaf in leaf1 leaf2; do
      echo "-- $leaf neighbors $ip received-routes"
      docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
        exec -T "$leaf" vtysh -c "show ip bgp neighbors $ip received-routes" || true
    done
  done
  echo "---- SERVERS-IN route-map ----"
  docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T leaf1 vtysh -c 'show route-map SERVERS-IN'
  echo "---- arping 10.98.0.10 on kind-eg (expect 0 — nobody ARPs for a routed address) ----"
  docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -b -c 3 -I eth0 "$HTTP_ADDR" 2>&1 || true
}
export -f doors_local
export PROJECT FABRIC CLUSTER HTTP_ADDR
rec bash -c doors_local
unset -f doors_local

# ---- 4. From client0 ----
echo "== 4. client0 through the fabric"
client0_http() {
  local rc=0 hdr code served
  echo "---- grpcurl --version (netshoot) ----"
  docker exec "$CLIENT" grpcurl --version 2>&1 || true
  echo "---- curl --resolve $HTTP_HOST:80:$HTTP_ADDR /healthz ----"
  hdr=$(docker exec "$CLIENT" curl -s --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
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
  echo "---- ip route get $HTTP_ADDR ----"
  docker exec "$CLIENT" ip route get "$HTTP_ADDR" || true
  echo "---- traceroute -T -p 80 -n $HTTP_ADDR (edge → spine → leaf → node; TCP to the door's port — UDP probes to high ports are not kube-proxy's and the node forwards them onward, measured) ----"
  docker exec "$CLIENT" traceroute -T -p 80 -n -m 8 "$HTTP_ADDR" || true
}
export -f client0_http
export CLIENT HTTP_HOST HTTP_ADDR
rec bash -c client0_http
unset -f client0_http

# ---- 5. Switch to active-active (10b) ----
echo "== 5. kube-vip BGP active-active (10b)"
rec kubectl --context "$CTX" apply -f "$HERE/10b-kube-vip-ds-bgp-active-active.yaml"
t2=$(date +%s)
rec kubectl --context "$CTX" -n kube-system rollout status ds/kube-vip-ds --timeout=180s
# Count paths whose nexthop is inside 172.19.0.0/17 (a node). The leaf
# also keeps the door's own prefix learned from the spine (10.200.1.3,
# AS path 65100 65102 65021 via leaf2) — real BGP; never preferred
# while a direct node path exists. Judges count NODE paths only.
node_path_count() { # stdin: show ip bgp PREFIX json → count or FAIL
  python3 -c '
import ipaddress, json, sys
NET = ipaddress.ip_network("172.19.0.0/17")
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("FAIL"); raise SystemExit
def paths_of(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("paths"), list):
            return obj["paths"]
        for v in obj.values():
            found = paths_of(v)
            if found is not None:
                return found
    return None
def hop_ips(path):
    ips = []
    if not isinstance(path, dict):
        return ips
    for key in ("nexthop", "nexthops", "peer"):
        nh = path.get(key)
        if nh is None:
            continue
        items = nh if isinstance(nh, list) else [nh]
        for item in items:
            if isinstance(item, str):
                ips.append(item.split("/")[0])
            elif isinstance(item, dict):
                ip = item.get("ip") or item.get("nexthop")
                if ip:
                    ips.append(str(ip).split("/")[0])
    return ips
found = paths_of(data)
if found is None:
    print("FAIL"); raise SystemExit
n = 0
for p in found:
    for ip in hop_ips(p):
        try:
            if ipaddress.ip_address(ip) in NET:
                n += 1
                break
        except ValueError:
            continue
print(n)
'
}
aa_wait() { # want — the number of NODE paths expected on leaf1 (1 under
            # ETP Local: kube-vip advertises a Local Service only from the
            # node with its endpoint — pkg/endpoints/endpoints.go:75-81,
            # measured; 2 under ETP Cluster). Spine bounce is not a node.
  local want=${1:-2} i n
  for i in $(seq 1 90); do
    raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
      exec -T leaf1 vtysh -c 'show ip bgp 10.98.0.10/32 json' 2>&1) || raw=""
    n=$(printf '%s' "$raw" | node_path_count)
    if [ "$n" != FAIL ] && [ "${n:-0}" -ge "$want" ]; then
      echo "leaf1 node_paths=$n (want >= $want nodes) after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "apply.sh: leaf1 still has node_paths=$n for 10.98.0.10/32 after 90s (want $want)" >&2
  return 1
}
export -f node_path_count aa_wait
export PROJECT FABRIC
# the doors are still ETP Local here: expect ONE node (the one with the Envoy pod) — the second
# path arrives with ETP Cluster in step 6
rec bash -c 'aa_wait 1'
t3=$(date +%s)
echo "active-active converge (ETP Local, one node): $((t3 - t2))s"
aa_record() {
  echo "---- spine show ip bgp 10.98.0.10/32 ----"
  docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T spine vtysh -c 'show ip bgp 10.98.0.10/32'
  echo "---- leaf1 show ip bgp 10.98.0.10/32 (two node paths + the spine bounce) ----"
  docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T leaf1 vtysh -c 'show ip bgp 10.98.0.10/32'
  echo "---- spine ip route show 10.98.0.10 (expect two nexthops) ----"
  docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T spine ip route show 10.98.0.10 || true
  echo "---- leaf summaries ----"
  local leaf
  for leaf in leaf1 leaf2; do
    echo "-- $leaf"
    docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
      exec -T "$leaf" vtysh -c 'show bgp summary'
  done
}
export -f aa_record
export PROJECT FABRIC
rec bash -c aa_record
unset -f aa_record

# ---- 6. THE ETP EXPERIMENT ----
echo "== 6. ETP: Local (one node advertises — the pod's) then Cluster (both nodes — ECMP)"
etp_loop() { # label
  local label=$1 i rc code ok=0 fail=0
  echo "---- $label: 40 curls from client0 ----"
  echo "---- Envoy pod placement ----"
  kubectl --context "$CTX" -n envoy-gateway-system get pods -o wide \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw || true
  echo "---- iptables 10.98.0.10 counters before ----"
  local n
  for n in $(kind get nodes --name "$CLUSTER"); do
    printf '%s ' "$n"
    docker exec "$n" iptables -t nat -L -n -v 2>/dev/null | awk '/10\.98\.0\.10/{c+=$1} END{print c+0}' || echo 0
  done
  local pods=""
  for i in $(seq 1 40); do
    rc=0
    hdr=$(docker exec "$CLIENT" curl -s --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
      -D - -o /dev/null "http://${HTTP_HOST}/healthz" \
      --connect-timeout 3 --max-time 5) || rc=$?
    hdr=$(printf '%s' "$hdr" | tr -d '\r')
    code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
    served=$(printf '%s' "$hdr" | awk '
      tolower($0) ~ /^[[:space:]]*x-served-by:[[:space:]]*/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        gsub(/[[:space:]]+$/, "")
        print
        exit
      }')
    xpod=$(printf '%s' "$hdr" | awk '
      tolower($0) ~ /^[[:space:]]*x-pod:[[:space:]]*/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        gsub(/[[:space:]]+$/, "")
        print
        exit
      }')
    if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
      ok=$((ok + 1))
      pods="${pods}${xpod:-?} "
    else
      fail=$((fail + 1))
    fi
  done
  echo "$label ok=$ok fail=$fail x-pod=[${pods}]"
  echo "---- iptables 10.98.0.10 counters after ----"
  for n in $(kind get nodes --name "$CLUSTER"); do
    printf '%s ' "$n"
    docker exec "$n" iptables -t nat -L -n -v 2>/dev/null | awk '/10\.98\.0\.10/{c+=$1} END{print c+0}' || echo 0
  done
}
export -f etp_loop
export CLIENT HTTP_HOST HTTP_ADDR CTX CLUSTER
rec bash -c 'etp_loop ETP-Local'

switch_etp_cluster() {
  local uid_before uid_after etp_before etp_after
  uid_before=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw \
    -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true)
  etp_before=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw \
    -o jsonpath='{.items[0].spec.externalTrafficPolicy}' 2>/dev/null || true)
  echo "before: uid=$uid_before etp=$etp_before"
  kubectl --context "$CTX" apply -f "$HERE/20-gateways-bgp.yaml"
  sleep 2
  etp_after=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw \
    -o jsonpath='{.items[0].spec.externalTrafficPolicy}' 2>/dev/null || true)
  uid_after=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw \
    -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true)
  echo "after apply 20: uid=$uid_after etp=$etp_after"
  if [ "$etp_after" = Cluster ]; then
    if [ -n "$uid_before" ] && [ "$uid_before" = "$uid_after" ]; then
      echo "externalTrafficPolicy mutated in place (Service UID unchanged) — it is mutable"
    else
      echo "Envoy Gateway recreated the Service (UID changed); ETP Cluster"
    fi
  else
    echo "ETP still ${etp_after:-absent} — delete-and-recreate the Gateway"
    kubectl --context "$CTX" -n shop delete gateway bgp-http-gw bgp-grpc-gw --ignore-not-found
    local gw
    for gw in bgp-http-gw bgp-grpc-gw; do
      kubectl --context "$CTX" -n envoy-gateway-system wait svc \
        -l "gateway.envoyproxy.io/owning-gateway-name=$gw" --for=delete --timeout=60s
    done
    kubectl --context "$CTX" -n shop delete envoyproxy bgp-http-gw-proxy bgp-grpc-gw-proxy --ignore-not-found
    kubectl --context "$CTX" apply -f "$HERE/20-gateways-bgp.yaml"
  fi
  kubectl --context "$CTX" -n shop wait --for=condition=Programmed gateway/bgp-http-gw --timeout=180s
  kubectl --context "$CTX" -n shop wait --for=condition=Programmed gateway/bgp-grpc-gw --timeout=180s
  wait_envoy_deploy bgp-http-gw
  wait_envoy_deploy bgp-grpc-gw
  kubectl --context "$CTX" -n envoy-gateway-system wait deploy \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw \
    --for=jsonpath='{.status.readyReplicas}'=2 --timeout=180s
  kubectl --context "$CTX" -n envoy-gateway-system wait deploy \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-grpc-gw \
    --for=jsonpath='{.status.readyReplicas}'=2 --timeout=180s
  wait_route httproute shop-api-bgp
  wait_route grpcroute orders-bgp
  etp_final=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=bgp-http-gw \
    -o jsonpath='{.items[0].spec.externalTrafficPolicy}' 2>/dev/null || true)
  echo "final ETP=$etp_final"
}
export -f switch_etp_cluster wait_envoy_deploy wait_route
export CTX HERE
rec bash -c switch_etp_cluster
# ETP Cluster: every node has a (cluster-wide) endpoint, so both advertise — two paths on leaf1
rec bash -c 'aa_wait 2'
rec bash -c 'etp_loop ETP-Cluster'
unset -f etp_loop switch_etp_cluster aa_wait

# ---- 7. gRPC matrix from client0 ----
echo "== 7. gRPC matrix from client0 (demo 52's 14 tests; hostname grpc.eg-poc1.poc.local)"
matrix_setup() {
  docker exec "$CLIENT" mkdir -p /tmp/probe
  docker cp "$CA" "${CLIENT}:/tmp/eg-poc1-root-ca.crt"
  docker cp "$PROBE/." "${CLIENT}:/tmp/probe/"
  echo "copied $CA and $PROBE into $CLIENT:/tmp"
  docker exec "$CLIENT" grpcurl --version 2>&1 || true
}
export -f matrix_setup
export CLIENT CA PROBE
rec bash -c matrix_setup
unset -f matrix_setup

grpc_matrix() {
  local GRPCURL=(docker exec "$CLIENT" grpcurl)
  local CA_IN=/tmp/eg-poc1-root-ca.crt
  local PROBE_IN=/tmp/probe
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
  observed() {
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
  out=$("${GRPCURL[@]}" -cacert "$CA_IN" -authority "$GRPC_HOST" \
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

  echo "-- T8a shop.v1.Orders/NoSuchMethod (descriptor) → Code: Unimplemented + unknown method"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext \
    -import-path "$PROBE_IN" -proto probe.proto \
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
    -import-path "$PROBE_IN" -proto nope.proto \
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
  docker cp "$bogus" "${CLIENT}:/tmp/bogus.crt"
  rc=0
  out=$("${GRPCURL[@]}" -cacert /tmp/bogus.crt -authority "$GRPC_HOST" -max-time 10 \
    "${GRPC_ADDR}:443" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "T11_rc=$rc"
  rm -f "$bogus" "$bogus.key"
  docker exec "$CLIENT" rm -f /tmp/bogus.crt || true
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'failed to verify certificate'; then
    row T11 "TLS fails with bogus CA" "$(observed "$out") rc=$rc" PASS
  else
    row T11 "TLS fails with bogus CA" "$(observed "$out") rc=$rc" FAIL
  fi

  echo "-- T12 isolation: grpc authority at HTTP door 10.98.0.10; api host at gRPC door"
  rc=0
  out=$("${GRPCURL[@]}" -plaintext -authority "$GRPC_HOST" \
    "${HTTP_ADDR}:80" grpc.health.v1.Health/Check 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "isolation_grpcurl_rc=$rc"
  iso_grpc=$rc
  rc=0
  code=$(docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' \
    --resolve "${HTTP_HOST}:80:${GRPC_ADDR}" \
    "http://${HTTP_HOST}/healthz" --connect-timeout 5 --max-time 10) || rc=$?
  echo "isolation_http_code=${code} curl_rc=$rc"
  if [ "$iso_grpc" -ne 0 ] && [ "$code" = 404 ]; then
    row T12 "grpc@.10 not served; curl@.11 → 404" "grpcurl_rc=$iso_grpc http=$code" PASS
  else
    row T12 "grpc@.10 not served; curl@.11 → 404" "grpcurl_rc=$iso_grpc http=$code" FAIL
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
export CLIENT HTTP_HOST HTTP_ADDR GRPC_HOST GRPC_ADDR
matrix_fails=0
rec bash -c grpc_matrix || matrix_fails=$?
unset -f grpc_matrix

# ---- 8. The Mac path ----
echo "== 8. Mac path (VM route; sudo line printed, never run)"
rec scripts/fabric-vm-route.sh --apply
mac_half() {
  local line
  line=$(netstat -rn | grep '^10\.98' || true)
  if [ -z "$line" ]; then
    echo "Mac route absent — the client0 half is the record"
    echo "  sudo route -n add -net 10.98.0.0/24 192.168.64.2"
    return 0
  fi
  printf '%s\n' "$line"
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
  echo "mac http://${HTTP_HOST}/healthz @ ${HTTP_ADDR}:80 → ${code} X-Served-By=${served:--} curl_rc=$rc"
  rc=0
  go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 -plaintext \
    -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" grpc.health.v1.Health/Check || rc=$?
  echo "mac grpcurl_h2c_rc=$rc"
}
export -f mac_half
export HTTP_HOST HTTP_ADDR GRPC_HOST GRPC_ADDR
rec bash -c mac_half

browser_shot() {
  if ! netstat -rn | grep -q '^10\.98'; then
    echo "Mac route absent — screenshot skipped"
    return 0
  fi
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
unset -f mac_half browser_shot

# ---- 9. FAILURE, measured (two scenarios) ----
echo "== 9. BGP-only (delete kube-vip on the worker) then silent node (pause 75 s)"

leaf_node_paths() { # leaf → node-path count or FAIL
  local raw
  raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T "$1" vtysh -c 'show ip bgp 10.98.0.10/32 json' 2>&1) || raw=""
  printf '%s' "$raw" | node_path_count
}

leaf_peer_state() { # leaf ip
  local raw
  raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T "$1" vtysh -c 'show bgp summary json' 2>&1) || raw=""
  printf '%s' "$raw" | WORKER_IP="$2" python3 -c '
import json, os, sys
ip = os.environ["WORKER_IP"]
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("FAIL"); raise SystemExit
peers = {}
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("peers"), dict):
            peers.update(o["peers"])
        for v in o.values():
            walk(v)
walk(data)
p = peers.get(ip) or {}
print(p.get("state") or p.get("peerState") or p.get("bgpState") or "ABSENT")
'
}

servers_est_on_leaf() { # leaf → Established SERVERS (AS 65021) count
  local raw
  raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
    exec -T "$1" vtysh -c 'show bgp summary json' 2>&1) || raw=""
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print(0); raise SystemExit
peers = {}
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("peers"), dict):
            peers.update(o["peers"])
        for v in o.values():
            walk(v)
walk(data)
n = 0
for ip, p in peers.items():
    asn = str((p or {}).get("remoteAs") or (p or {}).get("remoteAS") or "")
    st = (p or {}).get("state") or (p or {}).get("peerState") or (p or {}).get("bgpState") or ""
    if asn == "65021" and st == "Established":
        n += 1
print(n)
'
}

worker_ready_line() {
  kubectl --context "$CTX" get node eg-poc1-worker \
    -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status} lastTransitionTime={.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\n"}' \
    2>&1 || echo "Ready=? lastTransitionTime=?"
}

shopapi_ready_eps() {
  local json
  json=$(kubectl --context "$CTX" -n shop get endpointslice \
    -l kubernetes.io/service-name=shopapi -o json 2>&1) || json=""
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("ready_eps=FAIL"); raise SystemExit
n = 0
for item in data.get("items") or []:
    for ep in item.get("endpoints") or []:
        cond = ep.get("conditions") or {}
        if cond.get("ready") is True:
            n += 1
print("ready_eps=%d" % n)
' 2>/dev/null || echo "ready_eps=FAIL"
}

# F3: both nodes × both leaves Established AND two node paths on both
# leaves — the seventh run's check ran during reconnect and read est=2.
recovery_wait() { # budget_s
  local budget=${1:-90} i leaf n est ok
  for i in $(seq 1 "$budget"); do
    ok=1
    for leaf in leaf1 leaf2; do
      est=$(servers_est_on_leaf "$leaf")
      n=$(leaf_node_paths "$leaf")
      if [ "${est:-0}" -lt 2 ] || [ "$n" = FAIL ] || [ "${n:-0}" -lt 2 ]; then
        ok=0
      fi
    done
    if [ "$ok" -eq 1 ]; then
      echo "recovery: 4 sessions Established; 2 node paths on both leaves after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "apply.sh: recovery wait failed after ${budget}s (need 4 sessions + 2 node paths on both leaves)" >&2
  return 1
}

# (A) BGP-only: delete the worker's kube-vip pod (DS restarts it).
# TCP close → NOTIFICATION, no hold time; leaf1 node paths 2 → 1 in
# a second or two. client0 2.5 s loop for 30 s expects ~0 failures
# (ECMP to the control-plane). Path back when the pod is Running.
failure_bgp_only() {
  local worker=eg-poc1-worker start now i rc code ok=0 fail=0 withdrawal="" recovery=""
  local kv_pod pn
  kv_pod=$(kubectl --context "$CTX" -n kube-system get pods \
    -l app.kubernetes.io/name=kube-vip-ds \
    --field-selector spec.nodeName="$worker" \
    -o jsonpath='{.items[0].metadata.name}' 2>&1) || kv_pod=""
  if [ -z "$kv_pod" ]; then
    echo "apply.sh: no kube-vip pod on $worker" >&2
    return 1
  fi
  echo "---- A: BGP-only — delete kube-vip pod $kv_pod on $worker ----"
  kubectl --context "$CTX" -n kube-system delete pod "$kv_pod"
  start=$(date +%s)
  while now=$(date +%s); [ $((now - start)) -lt 30 ]; do
    rc=0
    code=$(docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' \
      --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
      "http://${HTTP_HOST}/healthz" --connect-timeout 2 --max-time 2) || rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
    pn=$(leaf_node_paths leaf1)
    echo "t+$((now - start))s code=${code:-000} rc=$rc leaf1 node_paths=$pn"
    if [ "$pn" = 1 ] && [ -z "$withdrawal" ]; then
      withdrawal=$((now - start))
    fi
    if [ -n "$withdrawal" ] && [ "$pn" != FAIL ] && [ "${pn:-0}" -ge 2 ] && [ -z "$recovery" ]; then
      recovery=$((now - start))
    fi
    sleep 2.5
  done
  if [ -z "$recovery" ]; then
    for i in $(seq 1 60); do
      kubectl --context "$CTX" -n kube-system wait pod \
        -l app.kubernetes.io/name=kube-vip-ds \
        --field-selector spec.nodeName="$worker" \
        --for=condition=Ready --timeout=5s 2>/dev/null || true
      pn=$(leaf_node_paths leaf1)
      echo "leaf1 node_paths=$pn (A recovery)"
      if [ "$pn" != FAIL ] && [ "${pn:-0}" -ge 2 ]; then
        now=$(date +%s)
        recovery=$((now - start))
        echo "leaf1 two node paths again after ${recovery}s (pod Running)"
        break
      fi
      sleep 1
    done
  fi
  echo "A summary: withdrawal_s=${withdrawal:-none} ok=$ok fail=$fail recovery_s=${recovery:-none}"
}

# (B) silent node: pause the worker 75 s. BGP withdraws at hold 9 s
# (dynamic peer ABSENT); Kubernetes' node-monitor-grace-period ≈ 40 s
# before NotReady; endpoints stay until then, so probes keep failing.
# Per tick (~5 s): probe, leaf1 node paths, peer state, Ready
# condition + lastTransitionTime, shopapi EndpointSlice ready count.
failure_silent_node() {
  local worker=eg-poc1-worker start now rc code
  local worker_ip pn st ready_line eps
  local bgp_withdraw="" node_notready="" first_ok_after="" recovery=""
  worker_ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "$worker" 2>/dev/null || echo 172.19.0.3)
  trap 'docker unpause eg-poc1-worker 2>/dev/null || true' EXIT
  echo "---- B: silent node — pause $worker ($worker_ip) for 75 s ----"
  docker pause "$worker"
  start=$(date +%s)
  while now=$(date +%s); [ $((now - start)) -lt 75 ]; do
    rc=0
    code=$(docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' \
      --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
      "http://${HTTP_HOST}/healthz" --connect-timeout 2 --max-time 2) || rc=$?
    pn=$(leaf_node_paths leaf1)
    st=$(leaf_peer_state leaf1 "$worker_ip")
    ready_line=$(worker_ready_line)
    eps=$(shopapi_ready_eps)
    echo "t+$((now - start))s code=${code:-000} rc=$rc leaf1 node_paths=$pn peer $worker_ip state=$st $ready_line $eps"
    if [ "$pn" = 1 ] && [ -z "$bgp_withdraw" ]; then
      bgp_withdraw=$((now - start))
    fi
    # a frozen kubelet stops reporting, so the condition becomes Unknown, not False
    # (measured: Ready=Unknown at t+47 s) — anything but True is "not ready"
    if printf '%s' "$ready_line" | grep -q 'Ready=' && ! printf '%s' "$ready_line" | grep -q 'Ready=True' && [ -z "$node_notready" ]; then
      node_notready=$((now - start))
    fi
    if [ -n "$node_notready" ] && [ "$rc" -eq 0 ] && [ "$code" = 200 ] && [ -z "$first_ok_after" ]; then
      first_ok_after=$((now - start))
    fi
    sleep 5
  done
  echo "---- unpause $worker ----"
  docker unpause "$worker"
  trap - EXIT
  for i in $(seq 1 90); do
    ready_line=$(worker_ready_line)
    pn=$(leaf_node_paths leaf1)
    echo "recovery t+${i}s $ready_line leaf1 node_paths=$pn"
    if printf '%s' "$ready_line" | grep -q 'Ready=True' \
       && [ "$pn" != FAIL ] && [ "${pn:-0}" -ge 2 ]; then
      recovery=$i
      echo "node Ready and two node paths after ${i}s"
      break
    fi
    sleep 1
  done
  echo "B summary: bgp_withdraw_s=${bgp_withdraw:-none} node_notready_s=${node_notready:-none} first_ok_after_s=${first_ok_after:-none} recovery_s=${recovery:-none}"
}

export -f node_path_count leaf_node_paths leaf_peer_state servers_est_on_leaf \
  worker_ready_line shopapi_ready_eps recovery_wait failure_bgp_only failure_silent_node
export CLIENT HTTP_HOST HTTP_ADDR PROJECT FABRIC CTX
rec bash -c failure_bgp_only
rec bash -c 'recovery_wait 90'
rec bash -c failure_silent_node
rec bash -c 'recovery_wait 90'
unset -f leaf_node_paths leaf_peer_state servers_est_on_leaf \
  worker_ready_line shopapi_ready_eps recovery_wait failure_bgp_only failure_silent_node node_path_count

# ---- 10. hosts + final table ----
echo "== 10. hosts-entries.sh + final table"
rec "$HERE/hosts-entries.sh"
final_table() {
  echo "DOOR ADDRESS PATHS NODES CLIENT0"
  local gw addr paths
  for gw in bgp-http-gw bgp-grpc-gw; do
    if [ "$gw" = bgp-http-gw ]; then addr=$HTTP_ADDR; else addr=$GRPC_ADDR; fi
    raw=$(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml" \
      exec -T spine vtysh -c "show ip bgp ${addr}/32 json" 2>&1) || raw=""
    paths=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("?"); raise SystemExit
def paths_of(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("paths"), list):
            return obj["paths"]
        for v in obj.values():
            found = paths_of(v)
            if found is not None:
                return found
    return None
found = paths_of(data)
print(len(found) if found is not None else "?")
')
    echo "$gw $addr paths=$paths"
  done
  echo "demo 54 L2 doors .100/.101: unannounced (vip_arp=false) — restored by cleanup.sh"
}
export -f final_table
export PROJECT FABRIC HTTP_ADDR GRPC_ADDR
rec bash -c final_table
unset -f final_table wait_envoy_deploy wait_route

echo "demo 56 apply: done (demo 54 L2 doors .100/.101 unannounced)"
if [ "${matrix_fails:-0}" -ne 0 ]; then
  echo "demo 56 apply: gRPC matrix had $matrix_fails FAIL"
  exit 1
fi
