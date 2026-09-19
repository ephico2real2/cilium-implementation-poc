#!/usr/bin/env bash
# apply.sh — land demo 54 on eg-poc1: kube-vip (class-only), two Gateways
# (HTTP isolated from gRPC), shop-db + shopapi + grpc, the routes, L2 proof,
# MacBook clients, a headless-Chrome screenshot. Idempotent. No docker
# build (gotcha #118); kind load of existing images is allowed. shop-db
# is pulled from Docker Hub by the node — a pull is not a build.
#
#   demos/54-eg-poc1-kube-vip/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
HERE=demos/54-eg-poc1-kube-vip
TRANSCRIPT=$HERE/output/transcript.txt
CTX=kind-eg-poc1
CLUSTER=eg-poc1
CA=.tmp/eg-poc1-root-ca.crt
HTTP_ADDR=172.19.255.100
GRPC_ADDR=172.19.255.101
HTTP_HOST=api.eg-poc1.poc.local
GRPC_HOST=grpc.eg-poc1.poc.local
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '\n### %s — demo 54 apply\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TRANSCRIPT"
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
echo "== 0. preflight (no docker build — gotcha #118)"
if [ ! -f "$CA" ]; then
  echo "apply.sh: $CA missing — run scripts/eg-up.sh eg-poc1 (issue #60: never commit a root)" >&2
  exit 1
fi
rec kubectl --context "$CTX" get --raw /readyz
gc=$(kubectl --context "$CTX" get gatewayclass eg \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
if [ "$gc" != True ]; then
  echo "apply.sh: GatewayClass eg is not Accepted (got ${gc:-absent}) — run scripts/eg-up.sh eg-poc1" >&2
  exit 1
fi
iss=$(kubectl --context "$CTX" get clusterissuer eg-ca-issuer \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$iss" != True ]; then
  echo "apply.sh: ClusterIssuer eg-ca-issuer is not Ready (got ${iss:-absent}) — run scripts/eg-up.sh eg-poc1" >&2
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
  echo "---- eg-poc1 nodes on kind-eg (IPv4 + MAC) ----"
  docker ps --filter name=eg-poc1 --format '{{.Names}} {{.Status}}'
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

# ---- 2. kube-vip (clusters/eg/ is the source of truth — not copied) ----
echo "== 2. kube-vip RBAC + DS + cloud-provider (clusters/eg/) + ConfigMap"
rec kubectl --context "$CTX" apply \
  -f clusters/eg/kube-vip-rbac.yaml \
  -f clusters/eg/kube-vip-ds.yaml \
  -f clusters/eg/kube-vip-cloud-provider.yaml \
  -f "$HERE/10-kubevip-cm.yaml"
rec kubectl --context "$CTX" -n kube-system rollout status ds/kube-vip-ds --timeout=120s
rec kubectl --context "$CTX" -n kube-system wait deploy/kube-vip-cloud-provider \
  --for=condition=Available --timeout=120s

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
if need_kind_load shopapi || need_kind_load routedemo; then
  rec kind load docker-image shopapi:local routedemo:local --name "$CLUSTER"
else
  echo "skip kind load shopapi:local routedemo:local — crictl images already shows them on $CLUSTER"
fi

# ---- 4. certificate ----
echo "== 4. certificate eg-poc1-tls (Ready ≤ 90s)"
rec kubectl --context "$CTX" apply -f "$HERE/20-certificate.yaml"
rec kubectl --context "$CTX" -n shop wait certificate/eg-poc1-tls --for=condition=Ready --timeout=90s
print_leaf() {
  local pem
  pem=$(kubectl --context "$CTX" -n shop get secret eg-poc1-tls \
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
echo "== 6. shop-db + shopapi + grpc + routes (Accepted + ResolvedRefs)"
export -f wait_route
# shop-db is pulled from Docker Hub by the node — no docker build; gotcha
# #118 does not apply to a pull.
rec kubectl --context "$CTX" apply -f "$HERE/45-shop-db.yaml"
rec kubectl --context "$CTX" -n shop rollout status deploy/shop-db --timeout=180s
rec kubectl --context "$CTX" apply -f "$HERE/40-app.yaml"
rec kubectl --context "$CTX" -n shop wait deploy/shopapi --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" -n shop wait deploy/grpc --for=condition=Available --timeout=120s
rec kubectl --context "$CTX" apply -f "$HERE/50-routes.yaml"
rec bash -c 'wait_route httproute shop-api'
rec bash -c 'wait_route grpcroute grpc'

# ---- 7. L2 PROOF ----
echo "== 7. L2 PROOF (arping → MAC → node, /32 on eth0, kube-vip logs)"
l2_proof() { # ip
  local ip=$1 out mac node
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
  if [ "$node" != "?" ]; then
    echo "---- docker exec $node ip -4 addr show eth0 ----"
    docker exec "$node" ip -4 addr show eth0
  fi
  echo "---- kube-vip DS logs for $ip (adding VIP / successful add IP) ----"
  kubectl --context "$CTX" -n kube-system logs -l app.kubernetes.io/name=kube-vip-ds \
    --timestamps 2>/dev/null | grep "$ip" || true
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
mac_grpc() {
  local rc=0
  echo "-- gRPC h2c ${GRPC_HOST} ${GRPC_ADDR}:80"
  rc=0
  go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 -plaintext \
    -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" grpc.health.v1.Health/Check || rc=$?
  echo "grpcurl_h2c_rc=$rc"
  echo "-- gRPC TLS ${GRPC_HOST} ${GRPC_ADDR}:443"
  rc=0
  go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 -cacert "$CA" \
    -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:443" grpc.health.v1.Health/Check || rc=$?
  echo "grpcurl_tls_rc=$rc"
  echo "-- gRPC list (reflection) ${GRPC_HOST} ${GRPC_ADDR}:80"
  rc=0
  go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 -plaintext \
    -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" list || rc=$?
  echo "grpcurl_list_rc=$rc"
}
mac_isolation() {
  local rc=0 out code
  echo "-- isolation: grpcurl against HTTP door ${HTTP_ADDR}:80 with grpc authority (expect not SERVING)"
  rc=0
  out=$(go run github.com/fullstorydev/grpcurl/cmd/grpcurl@v1.9.4 -plaintext \
    -authority "$GRPC_HOST" \
    "${HTTP_ADDR}:80" grpc.health.v1.Health/Check 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "isolation_grpcurl_rc=$rc"
  echo "-- isolation: curl http://${HTTP_HOST}/healthz at gRPC door ${GRPC_ADDR}:80 (expect not 200)"
  rc=0
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    --resolve "${HTTP_HOST}:80:${GRPC_ADDR}" \
    "http://${HTTP_HOST}/healthz" --connect-timeout 5 --max-time 10) || rc=$?
  echo "isolation_http_code=${code} curl_rc=$rc"
}
export -f mac_http mac_https mac_orders mac_grpc mac_isolation
export HTTP_HOST HTTP_ADDR GRPC_HOST GRPC_ADDR CA
rec bash -c mac_http
rec bash -c mac_https
rec bash -c mac_orders
rec bash -c mac_grpc
rec bash -c mac_isolation
unset -f mac_http mac_https mac_orders mac_grpc mac_isolation

# ---- 9. THE BROWSER ----
echo "== 9. THE BROWSER (headless Chrome, no /etc/hosts)"
browser_shot() {
  if [ ! -x "$CHROME" ]; then
    echo "Chrome is absent at $CHROME — skipping screenshot"
    return 0
  fi
  local shot="$PWD/$HERE/output/browser.png" profile rc=0
  # Measured 2026-09-19: Chrome 153 writes the PNG and then hangs in a network-service
  # crash loop instead of exiting, so it runs under a 60 s timeout with a throwaway
  # profile; the PNG on disk is the result, not the exit code.
  profile=$(mktemp -d)
  rm -f "$shot"
  echo "timeout 60 $CHROME --headless=new --disable-gpu --no-first-run --window-size=1000,500 --user-data-dir=<tmp> --host-resolver-rules=\"MAP ${HTTP_HOST} ${HTTP_ADDR}\" --screenshot=$shot http://${HTTP_HOST}/orders"
  timeout 60 "$CHROME" --headless=new --disable-gpu --no-first-run --window-size=1000,500 \
    --user-data-dir="$profile" \
    --host-resolver-rules="MAP ${HTTP_HOST} ${HTTP_ADDR}" \
    --screenshot="$shot" \
    "http://${HTTP_HOST}/orders" >/dev/null 2>&1 || rc=$?
  rm -rf "$profile"
  echo "chrome_rc=$rc (124 = killed by the timeout after writing the file)"
  if [ -s "$shot" ]; then
    file "$HERE/output/browser.png"
  else
    # recorded, not fatal: apply records what happened, check.sh judges it
    echo "no screenshot written"
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

CTX = "kind-eg-poc1"
CA = ".tmp/eg-poc1-root-ca.crt"
HTTP_ADDR = "172.19.255.100"
GRPC_ADDR = "172.19.255.101"
HTTP_HOST = "api.eg-poc1.poc.local"
GRPC_HOST = "grpc.eg-poc1.poc.local"
KV_CLASS = "kube-vip.io/kube-vip-class"

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

print(f"{'DOOR':<10} {'ADDRESS':<16} {'PROG':<6} {'CLASS':<28} {'ANNOUNCED_BY':<22} {'HTTP_or_GRPC'}")
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
    print(f"{gw:<10} {addr:<16} {prog or '?':<6} {klass:<28} {node:<22} {cell}")
PY
}
export -f final_table
rec bash -c final_table
unset -f final_table wait_envoy_deploy wait_route

echo "demo 54 apply: done"
