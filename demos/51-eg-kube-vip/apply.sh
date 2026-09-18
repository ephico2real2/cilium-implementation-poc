#!/usr/bin/env bash
# apply.sh — land demo 51 on both EG clusters: kube-vip (class-only), the doors,
# shopapi + grpc, the routes, the R7 experiment, the VIP move, the probes.
# Idempotent. No docker build (gotcha #118); kind load of existing images is allowed.
#
#   demos/51-eg-kube-vip/apply.sh
#   VIP_HOME=eg2 demos/51-eg-kube-vip/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
HERE=demos/51-eg-kube-vip
TRANSCRIPT=$HERE/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '\n### %s — demo 51 apply (VIP_HOME=%s)\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${VIP_HOME:-eg1}" >>"$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

CLUSTERS="${CLUSTERS:-eg1 eg2}"
VIP_HOME="${VIP_HOME:-eg1}"
# shellcheck disable=SC2206
CLUSTER_ARR=($CLUSTERS)
KV_CLASS=kube-vip.io/kube-vip-class
CA=.tmp/eg-root-ca.crt

yaml_select() { # file name [name...]
  python3 - "$@" <<'PY'
import sys, re
path, *names = sys.argv[1:]
want = set(names)
text = open(path).read()
for part in re.split(r"(?m)^---\s*\n", text):
    m = re.search(r"(?m)^  name:\s+(\S+)", part)
    if not m:
        m = re.search(r"metadata:\s*\{name:\s*([^,\s}]+)", part)
    if m and m.group(1) in want:
        sys.stdout.write("---\n")
        sys.stdout.write(part if part.endswith("\n") else part + "\n")
PY
}

ctx_of() { echo "kind-$1"; }

gw_name() { # cluster → per-cluster Gateway name
  echo "$1-gw"
}

gw_file() {
  echo "$HERE/30-gateways-$1.yaml"
}

routes_file() {
  echo "$HERE/50-routes-$1.yaml"
}

cm_file() {
  echo "$HERE/10-kubevip-cm-$1.yaml"
}

local_addr() {
  case "$1" in
    eg1) echo 172.19.255.240 ;;
    eg2) echo 172.19.255.176 ;;
  esac
}

local_host() {
  case "$1" in
    eg1) echo api.eg1.poc.local ;;
    eg2) echo api.eg2.poc.local ;;
  esac
}

grpc_host() {
  case "$1" in
    eg1) echo grpc.eg1.poc.local ;;
    eg2) echo grpc.eg2.poc.local ;;
  esac
}

r7_addr() {
  case "$1" in
    eg1) echo 172.19.255.245 ;;
    eg2) echo 172.19.255.181 ;;
  esac
}

need_kind_load() { # cluster needle — 0 if any node is missing the image
  local cluster=$1 needle=$2 node
  for node in $(kind get nodes --name "$cluster"); do
    if ! docker exec "$node" crictl images 2>/dev/null | grep -q "$needle"; then
      return 0
    fi
  done
  return 1
}

wait_envoy_deploy() { # ctx gateway-name
  local ctx=$1 gw=$2 i
  for i in $(seq 1 36); do
    if kubectl --context "$ctx" -n envoy-gateway-system get deploy \
         -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
         -o name 2>/dev/null | grep -q .; then
      kubectl --context "$ctx" -n envoy-gateway-system wait deploy \
        -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
        --for=condition=Available --timeout=180s
      return 0
    fi
    sleep 5
  done
  echo "apply.sh: no Envoy Deployment for $gw on $ctx after 180s" >&2
  kubectl --context "$ctx" -n envoy-gateway-system get deploy,svc >&2 || true
  return 1
}

wait_route() { # ctx kind name
  local ctx=$1 kind=$2 name=$3 i json
  for i in $(seq 1 24); do
    json=$(kubectl --context "$ctx" -n shop get "$kind" "$name" -o json 2>/dev/null || true)
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
      echo "$ctx $kind/$name: all parents Accepted+ResolvedRefs"
      return 0
    fi
    sleep 5
  done
  echo "apply.sh: $ctx $kind/$name NOT ready after 120s" >&2
  kubectl --context "$ctx" -n shop get "$kind" "$name" -o yaml >&2 || true
  return 1
}

envoy_svc_json() { # ctx gw — first Service owned by the Gateway
  kubectl --context "$1" -n envoy-gateway-system get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$2" -o json 2>/dev/null
}

# ---- 0. preflight ----
echo "== 0. no docker build (gotcha #118). kind load of shopapi:local and routedemo:local is allowed."
if [ ! -f "$CA" ]; then
  echo "apply.sh: $CA missing — demo 50's scripts/eg-up.sh exports it (issue #60: never commit a root)" >&2
  exit 1
fi
for c in "${CLUSTER_ARR[@]}"; do
  rec kubectl --context "$(ctx_of "$c")" get --raw /readyz
done

# ---- 1. kube-vip on both clusters (phase 0 files — one source of truth) ----
echo "== 1. kube-vip RBAC + DS + cloud-provider (clusters/eg/) + per-cluster ConfigMap"
for c in "${CLUSTER_ARR[@]}"; do
  ctx=$(ctx_of "$c")
  rec kubectl --context "$ctx" apply -f clusters/eg/kube-vip-rbac.yaml
  rec kubectl --context "$ctx" apply -f "$(cm_file "$c")"
  rec kubectl --context "$ctx" apply -f clusters/eg/kube-vip-ds.yaml
  rec kubectl --context "$ctx" apply -f clusters/eg/kube-vip-cloud-provider.yaml
  rec kubectl --context "$ctx" -n kube-system rollout status ds/kube-vip-ds --timeout=120s
  rec kubectl --context "$ctx" -n kube-system wait deploy/kube-vip-cloud-provider --for=condition=Available --timeout=120s
done

# ---- 2. namespace, ConfigMap, standing D11 exhibit, kind load ----
echo "== 2. namespace shop, ConfigMap eg-cluster, probe-noclass, kind load"
for c in "${CLUSTER_ARR[@]}"; do
  ctx=$(ctx_of "$c")
  rec kubectl --context "$ctx" apply -f "$HERE/00-namespaces.yaml"
  rec kubectl --context "$ctx" apply -f "$HERE/15-probe-noclass.yaml"
  rec bash -c "kubectl --context $ctx apply -f -" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: eg-cluster
  namespace: shop
data:
  name: $c
EOF
  if need_kind_load "$c" shopapi; then
    rec kind load docker-image shopapi:local --name "$c"
  else
    echo "skip kind load shopapi:local — crictl images already shows it on $c"
  fi
  if need_kind_load "$c" routedemo; then
    rec kind load docker-image routedemo:local --name "$c"
  else
    echo "skip kind load routedemo:local — crictl images already shows it on $c"
  fi
done

# ---- 3. certificate ----
echo "== 3. certificate eg-tls (Ready ≤ 90s)"
for c in "${CLUSTER_ARR[@]}"; do
  ctx=$(ctx_of "$c")
  rec kubectl --context "$ctx" apply -f "$HERE/20-certificates.yaml"
  rec kubectl --context "$ctx" -n shop wait certificate/eg-tls --for=condition=Ready --timeout=90s
done

# ---- 4. EnvoyProxies then Gateways (per-cluster always; VIP in VIP_HOME only) ----
echo "== 4. EnvoyProxies + Gateways (Programmed ≤ 180s; Envoy Deployment Available)"
export -f yaml_select wait_envoy_deploy
for c in "${CLUSTER_ARR[@]}"; do
  ctx=$(ctx_of "$c")
  gw=$(gw_name "$c")
  rec bash -c 'yaml_select "$1" "$2-proxy" "$2" | kubectl --context "$3" apply -f -' \
    bash "$(gw_file "$c")" "$gw" "$ctx"
  rec kubectl --context "$ctx" -n shop wait --for=condition=Programmed "gateway/$gw" --timeout=180s
  rec bash -c 'wait_envoy_deploy "$1" "$2"' bash "$ctx" "$gw"
done

if printf '%s\n' "${CLUSTER_ARR[@]}" | grep -qx "$VIP_HOME"; then
  echo "== 4b. VIP Gateway on $VIP_HOME only (delete-other-first)"
  rec scripts/eg-vip-move.sh kube-vip "$VIP_HOME"
else
  echo "== 4b. skipped: VIP_HOME=$VIP_HOME not in CLUSTERS=$CLUSTERS"
fi

# ---- 5. app ----
echo "== 5. shopapi + grpc (Available ≤ 120s)"
for c in "${CLUSTER_ARR[@]}"; do
  ctx=$(ctx_of "$c")
  rec kubectl --context "$ctx" apply -f "$HERE/40-app.yaml"
  rec kubectl --context "$ctx" -n shop wait deploy/shopapi --for=condition=Available --timeout=120s
  rec kubectl --context "$ctx" -n shop wait deploy/grpc --for=condition=Available --timeout=120s
done

# ---- 6. routes ----
echo "== 6. HTTPRoutes + GRPCRoutes (Accepted + ResolvedRefs)"
export -f wait_route
for c in "${CLUSTER_ARR[@]}"; do
  ctx=$(ctx_of "$c")
  rec bash -c 'yaml_select "$1" shop-api shop-redirect grpc | kubectl --context "$2" apply -f -' \
    bash "$(routes_file "$c")" "$ctx"
  rec bash -c 'wait_route "$1" httproute shop-api' bash "$ctx"
  rec bash -c 'wait_route "$1" httproute shop-redirect' bash "$ctx"
  rec bash -c 'wait_route "$1" grpcroute grpc' bash "$ctx"
done
if printf '%s\n' "${CLUSTER_ARR[@]}" | grep -qx "$VIP_HOME"; then
  vctx=$(ctx_of "$VIP_HOME")
  rec bash -c 'yaml_select "$1" shop-api-vip shop-redirect-vip grpc-vip | kubectl --context "$2" apply -f -' \
    bash "$(routes_file "$VIP_HOME")" "$vctx"
  rec bash -c 'wait_route "$1" httproute shop-api-vip' bash "$vctx"
  rec bash -c 'wait_route "$1" httproute shop-redirect-vip' bash "$vctx"
  rec bash -c 'wait_route "$1" grpcroute grpc-vip' bash "$vctx"
fi

# ---- 7. hosts block (operator adds it; checks use --resolve) ----
echo "== 7. hosts-entries.sh (operator adds this to /etc/hosts; checks use --resolve)"
rec "$HERE/hosts-entries.sh"

# ---- 8. R7 experiment — spec.addresses alone, once per cluster ----
echo "== 8. R7 EXPERIMENT — Gateway.spec.addresses only (no EnvoyProxy)"
r7_one() { # cluster
  local c=$1 ctx ip
  ctx=$(ctx_of "$c")
  ip=$(r7_addr "$c")
  echo "---- R7 $c probe-noproxy addresses=$ip (no EnvoyProxy) ----"
  kubectl --context "$ctx" -n shop apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: probe-noproxy
  namespace: shop
spec:
  gatewayClassName: eg
  addresses:
    - type: IPAddress
      value: "$ip"
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
EOF
  local i svc_json ext lb
  for i in $(seq 1 36); do
    svc_json=$(envoy_svc_json "$ctx" probe-noproxy)
    if printf '%s' "$svc_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("items") else 1)' 2>/dev/null; then
      break
    fi
    sleep 5
  done
  ext=$(printf '%s' "$svc_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); items=d.get("items") or []; print((items[0].get("spec") or {}).get("externalIPs",[]) if items else [])')
  lb=$(printf '%s' "$svc_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); items=d.get("items") or []; print((items[0].get("status") or {}).get("loadBalancer",{}) if items else {})')
  echo "R7 $c Service externalIPs=$ext status.loadBalancer=$lb"
  echo "R7 $c arping $ip (expect 0 replies)"
  docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -c 3 -I eth0 "$ip" 2>&1 || true
  kubectl --context "$ctx" -n shop delete gateway probe-noproxy --ignore-not-found
  echo "R7 $c probe-noproxy deleted"
}
export -f r7_one r7_addr ctx_of envoy_svc_json
for c in "${CLUSTER_ARR[@]}"; do
  rec bash -c 'r7_one "$1"' bash "$c" || echo "R7 $c: recorded a contradiction; continuing"
done
unset -f r7_one

# ---- 9. VIP move to the other cluster and back, with measured gap ----
echo "== 9. VIP move (delete-other-first) with arping + curl gap"
OTHER=eg2
if [ "$VIP_HOME" = eg2 ]; then
  OTHER=eg1
fi

measure_move() { # target
  local target=$1
  local log stop pid ts code nfail nok first_fail last_fail gap
  log=$(mktemp)
  stop=$(mktemp)
  (
    while [ -f "$stop" ]; do
      ts=$(python3 -c 'import time; print("%.3f" % time.time())')
      code=$(curl -sk -m 1 --resolve "api.eg.poc.local:443:172.19.255.16" \
        --cacert "$CA" "https://api.eg.poc.local/healthz" \
        -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)
      echo "$ts $code" >>"$log"
      sleep 0.5
    done
  ) &
  pid=$!
  sleep 1
  echo "-- arping .16 BEFORE move to $target"
  docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -c 3 -I eth0 172.19.255.16 2>&1 || true
  if ! scripts/eg-vip-move.sh kube-vip "$target"; then
    echo "VIP move to $target failed — recorded; continuing"
    rm -f "$stop"
    wait "$pid" || true
    rm -f "$log" "$stop"
    return 0
  fi
  echo "-- arping .16 AFTER move to $target"
  docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -c 3 -I eth0 172.19.255.16 2>&1 || true
  sleep 2
  rm -f "$stop"
  wait "$pid" || true
  python3 - "$log" "$target" <<'PY'
import sys
path, target = sys.argv[1], sys.argv[2]
rows = []
for line in open(path):
    parts = line.split()
    if len(parts) != 2:
        continue
    rows.append((float(parts[0]), parts[1]))
if not rows:
    print(f"VIP move {target}: no probe samples")
    sys.exit(0)
fails = [(t, c) for t, c in rows if c != "200"]
oks = [(t, c) for t, c in rows if c == "200"]
print(f"VIP move {target}: samples={len(rows)} ok={len(oks)} fail={len(fails)}")
if fails:
    gap = fails[-1][0] - fails[0][0]
    print(f"VIP move {target}: first_fail={fails[0][0]:.3f} last_fail={fails[-1][0]:.3f} gap_s={gap:.3f}")
else:
    print(f"VIP move {target}: gap_s=0.000 (no failed probes)")
PY
  rm -f "$log"
}
export -f measure_move
export CA
rec bash -c 'measure_move "$1"' bash "$OTHER" || echo "VIP move $OTHER: recorded; continuing"
rec bash -c 'measure_move "$1"' bash "$VIP_HOME" || echo "VIP move $VIP_HOME: recorded; continuing"
unset -f measure_move
rec scripts/eg-vip-move.sh --status

# ---- 10. probes: curl --resolve, 301s, gRPC, shopctl ----
echo "== 10. probes (curl --resolve, 301, grpcurl, shopctl)"

https_probe() { # host addr
  local host=$1 addr=$2 hdr code served
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
  echo "https://$host @ $addr → ${code:-000} X-Served-By=${served:--}"
}

redirect_probe() { # host addr
  local host=$1 addr=$2 code loc
  code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$host:80:$addr" \
    "http://$host/healthz" --connect-timeout 5 --max-time 10 2>/dev/null || echo 000)
  loc=$(curl -sI --resolve "$host:80:$addr" "http://$host/healthz" \
    --connect-timeout 5 --max-time 10 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="location:"{print $2; exit}')
  echo "http://$host @ $addr → ${code:-000} Location=${loc:--}"
}

grpc_probe() { # authority addr
  local auth=$1 addr=$2
  echo "-- gRPC h2c $auth $addr:80"
  docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
    -plaintext -max-time 10 -authority "$auth" \
    "${addr}:80" grpc.health.v1.Health/Check || true
  echo "-- gRPC TLS $auth $addr:443"
  docker run --rm --network kind-eg \
    -v "$PWD/$CA:/ca.crt:ro" fullstorydev/grpcurl:latest \
    -cacert /ca.crt -max-time 10 -authority "$auth" \
    "${addr}:443" grpc.health.v1.Health/Check || true
  echo "-- gRPC list (reflection) $auth $addr:80"
  docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
    -plaintext -max-time 10 -authority "$auth" \
    "${addr}:80" list || true
}
export -f https_probe redirect_probe grpc_probe
export CA

for c in "${CLUSTER_ARR[@]}"; do
  rec bash -c 'https_probe "$1" "$2"' bash "$(local_host "$c")" "$(local_addr "$c")"
  rec bash -c 'redirect_probe "$1" "$2"' bash "$(local_host "$c")" "$(local_addr "$c")"
  rec bash -c 'grpc_probe "$1" "$2"' bash "$(grpc_host "$c")" "$(local_addr "$c")"
done
rec bash -c 'https_probe api.eg.poc.local 172.19.255.16'
rec bash -c 'redirect_probe api.eg.poc.local 172.19.255.16'
rec bash -c 'grpc_probe grpc.eg.poc.local 172.19.255.16'

echo "== 10b. shopctl probe (needs /etc/hosts; WARN + print the block if the name does not resolve)"
shopctl_probe() {
  local host=api.eg.poc.local
  local os arch go_bin addresses
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
  esac
  go_bin="demos/40-shop-mesh-phase0/client/go/shopctl/bin/shopctl-${os}-${arch}"
  py=demos/40-shop-mesh-phase0/client/python/shopctl.py
  if [ "$(uname -s)" = Darwin ]; then
    addresses=$(dscacheutil -q host -a name "$host" 2>/dev/null | awk '$1=="ip_address:" {print $2}')
  else
    addresses=$(getent hosts "$host" 2>/dev/null | awk '{print $1}')
  fi
  if ! printf '%s\n' "$addresses" | grep -Fxq 172.19.255.16; then
    echo "WARN: $host resolves to ${addresses:-nothing}; live VIP is 172.19.255.16."
    echo "Replace the stale (or missing) hosts entry with:"
    demos/51-eg-kube-vip/hosts-entries.sh
    echo "  demos/51-eg-kube-vip/hosts-entries.sh | sudo tee -a /etc/hosts"
    return 0
  fi
  echo "-- shopctl (Go) probe --cacert $CA"
  "$go_bin" probe --url "https://$host" --cacert "$CA" || true
  echo "-- shopctl.py probe --cacert $CA"
  python3 "$py" probe --url "https://$host" --cacert "$CA" || true
}
export -f shopctl_probe
export CA
rec bash -c shopctl_probe
unset -f shopctl_probe https_probe redirect_probe grpc_probe

# ---- 11. final table ----
echo "== 11. final table per cluster"
final_table() {
  python3 - <<'PY'
import json, subprocess, os

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
         "busybox:1.36", "arping", "-c", "3", "-I", "eth0", ip],
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

def https(host, addr):
    p = subprocess.run(
        ["curl", "-sk", "--resolve", f"{host}:443:{addr}",
         "--cacert", ".tmp/eg-root-ca.crt",
         f"https://{host}/healthz", "-D", "-", "-o", "/dev/null",
         "--connect-timeout", "5", "--max-time", "10"],
        capture_output=True, text=True)
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
        args = ["docker", "run", "--rm", "--network", "kind-eg",
                "-v", os.path.abspath(".tmp/eg-root-ca.crt") + ":/ca.crt:ro",
                "fullstorydev/grpcurl:latest",
                "-cacert", "/ca.crt", "-max-time", "10",
                "-authority", auth, f"{addr}:443",
                "grpc.health.v1.Health/Check"]
    else:
        args = ["docker", "run", "--rm", "--network", "kind-eg",
                "fullstorydev/grpcurl:latest",
                "-plaintext", "-max-time", "10",
                "-authority", auth, f"{addr}:80",
                "grpc.health.v1.Health/Check"]
    p = subprocess.run(args, capture_output=True, text=True)
    out = p.stdout + p.stderr
    return "SERVING" if "SERVING" in out else "FAIL"

doors = [
    ("eg1", "kind-eg1", "eg1-gw",    "172.19.255.240", "api.eg1.poc.local",  "grpc.eg1.poc.local"),
    ("eg1", "kind-eg1", "eg-vip-gw", "172.19.255.16",  "api.eg.poc.local",   "grpc.eg.poc.local"),
    ("eg2", "kind-eg2", "eg2-gw",    "172.19.255.176", "api.eg2.poc.local",  "grpc.eg2.poc.local"),
    ("eg2", "kind-eg2", "eg-vip-gw", "172.19.255.16",  "api.eg.poc.local",   "grpc.eg.poc.local"),
]
print(f"{'CLUSTER':<8} {'DOOR':<10} {'ADDRESS':<16} {'PROG':<6} {'LB_CLASS':<28} {'ANNOUNCED_BY':<22} {'HTTP':<12} {'GRPC_H2C':<10} {'GRPC_TLS'}")
for cluster, ctx, gw, addr, host, ghost in doors:
    exists = subprocess.run(
        ["kubectl", "--context", ctx, "-n", "shop", "get", "gateway", gw],
        capture_output=True).returncode == 0
    if not exists:
        continue
    prog, _ = run(["kubectl", "--context", ctx, "-n", "shop", "get", "gateway", gw,
                   "-o", "jsonpath={.status.conditions[?(@.type==\"Programmed\")].status}"])
    svc = subprocess.run(
        ["kubectl", "--context", ctx, "-n", "envoy-gateway-system", "get", "svc",
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
    http = https(host, addr)
    h2c = grpc(ghost, addr, False)
    tls = grpc(ghost, addr, True)
    print(f"{cluster:<8} {gw:<10} {addr:<16} {prog or '?':<6} {klass:<28} {node:<22} {http:<12} {h2c:<10} {tls}")
PY
}
export -f final_table
rec bash -c final_table
unset -f final_table wait_envoy_deploy wait_route yaml_select

echo "== 12. check.sh (PASS/FAIL rows; a FAIL row fails this script)"
rec "$HERE/check.sh"

echo "demo 51 apply: done"
