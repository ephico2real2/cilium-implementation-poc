#!/usr/bin/env bash
# apply.sh — demo 54c: one kind cluster in the Colima VM, kube-vip BGP
# to both leaves, a door /32, dashboard showing the nodes. Idempotent.
# Envoy Gateway is not required. No kind load — images go through
# kind-registry. Every docker call is --context "$CTX".
#   demos/54-eg-poc1-kube-vip-colima/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi
if ! fabric_colima_require_ctx; then
  exit 1
fi

fabric_colima_save_ctx
trap fabric_colima_restore_ctx EXIT

if ! fabric_colima_kind_env; then
  exit 1
fi

if [ -f "$FABRIC_COLIMA_FABRIC/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$FABRIC_COLIMA_FABRIC/.env"
  set +a
fi
export FABRIC_BGP_PASSWORD="${FABRIC_BGP_PASSWORD:-lab-bgp}"

export RECORD_STRICT=1
HERE=demos/54-eg-poc1-kube-vip-colima
TRANSCRIPT=$HERE/output/transcript.txt
DASH="http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}"
KCTX="kind-$EG_COLIMA_CLUSTER"
DOOR_ADDR="${EG_COLIMA_DOOR}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p "$(dirname "$TRANSCRIPT")" .tmp
printf '\n### %s — demo 54c apply\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

compose_lan() {
  docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" \
    -f "$FABRIC_COLIMA_FABRIC/compose.lan-eg.yaml" "$@"
}
export -f compose_lan

echo "== 0. preflight (fabric up; CTX=$CTX; kubeconfig=$KUBECONFIG)"
ps_out=$(docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" \
  ps --format '{{.Name}} {{.Service}} {{.State}} {{.Health}}' 2>&1) || ps_out=""
leaf_ok=1
for svc in edge spine leaf1 leaf2; do
  if ! printf '%s\n' "$ps_out" | grep -Eq "${FABRIC_COLIMA_PROJECT}-${svc}-[0-9]+ ${svc} running"; then
    leaf_ok=0
  fi
done
if [ "$leaf_ok" -ne 1 ]; then
  echo "apply.sh: fabric not up in $CTX. run demos/46-bgp-fabric-colima/apply.sh" >&2
  exit 1
fi
echo "preflight: project $FABRIC_COLIMA_PROJECT running; password set=${FABRIC_BGP_PASSWORD:+yes}"

echo "== 1. node LAN + registry + cluster (scripts/eg-colima-up.sh)"
rec scripts/eg-colima-up.sh

echo "== 2. attach leaves to $KIND_EG_COLIMA_NET at ${KIND_EG_COLIMA_LEAF1}/.12 (--no-recreate)"
# shellcheck disable=SC2329
attach_leaves() {
  set -euo pipefail
  local id1_before id2_before id1_after id2_after ip11 ip12
  id1_before=$(docker --context "$CTX" inspect -f '{{.Id}}' "${FABRIC_COLIMA_PROJECT}-leaf1-1")
  id2_before=$(docker --context "$CTX" inspect -f '{{.Id}}' "${FABRIC_COLIMA_PROJECT}-leaf2-1")
  echo "before: leaf1=$id1_before leaf2=$id2_before"
  docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" \
    -f "$FABRIC_COLIMA_FABRIC/compose.lan-eg.yaml" \
    up -d --no-recreate --no-build
  id1_after=$(docker --context "$CTX" inspect -f '{{.Id}}' "${FABRIC_COLIMA_PROJECT}-leaf1-1")
  id2_after=$(docker --context "$CTX" inspect -f '{{.Id}}' "${FABRIC_COLIMA_PROJECT}-leaf2-1")
  echo "after:  leaf1=$id1_after leaf2=$id2_after"
  if [ "$id1_before" != "$id1_after" ] || [ "$id2_before" != "$id2_after" ]; then
    echo "WARNING: a leaf container was recreated (ids changed)"
  else
    echo "leaves not recreated (same container ids)"
  fi
  ip11=$(docker --context "$CTX" inspect -f \
    "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" \
    "${FABRIC_COLIMA_PROJECT}-leaf1-1" 2>/dev/null || true)
  ip12=$(docker --context "$CTX" inspect -f \
    "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" \
    "${FABRIC_COLIMA_PROJECT}-leaf2-1" 2>/dev/null || true)
  if [ "$ip11" != "$KIND_EG_COLIMA_LEAF1" ]; then
    echo "leaf1 not at $KIND_EG_COLIMA_LEAF1 (got ${ip11:-absent}) — docker network connect"
    docker --context "$CTX" network connect --ip "$KIND_EG_COLIMA_LEAF1" \
      "$KIND_EG_COLIMA_NET" "${FABRIC_COLIMA_PROJECT}-leaf1-1" 2>/dev/null || true
    ip11=$(docker --context "$CTX" inspect -f \
      "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" \
      "${FABRIC_COLIMA_PROJECT}-leaf1-1")
  fi
  if [ "$ip12" != "$KIND_EG_COLIMA_LEAF2" ]; then
    echo "leaf2 not at $KIND_EG_COLIMA_LEAF2 (got ${ip12:-absent}) — docker network connect"
    docker --context "$CTX" network connect --ip "$KIND_EG_COLIMA_LEAF2" \
      "$KIND_EG_COLIMA_NET" "${FABRIC_COLIMA_PROJECT}-leaf2-1" 2>/dev/null || true
    ip12=$(docker --context "$CTX" inspect -f \
      "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" \
      "${FABRIC_COLIMA_PROJECT}-leaf2-1")
  fi
  echo "leaf1 $KIND_EG_COLIMA_NET=$ip11 leaf2 $KIND_EG_COLIMA_NET=$ip12"
  if [ "$ip11" != "$KIND_EG_COLIMA_LEAF1" ] || [ "$ip12" != "$KIND_EG_COLIMA_LEAF2" ]; then
    echo "apply.sh: leaves not at ${KIND_EG_COLIMA_LEAF1}/.12" >&2
    return 1
  fi
}
export -f attach_leaves
export CTX FABRIC_COLIMA_PROJECT FABRIC_COLIMA_FABRIC KIND_EG_COLIMA_NET KIND_EG_COLIMA_LEAF1 KIND_EG_COLIMA_LEAF2
rec bash -c attach_leaves
unset -f attach_leaves

echo "== 3. push images to localhost:${KIND_REGISTRY_PORT} (no kind load)"
# shellcheck disable=SC2329
push_images() {
  set -euo pipefail
  docker --context "$CTX" pull "ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}"
  docker --context "$CTX" tag "ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}" \
    "localhost:${KIND_REGISTRY_PORT}/kube-vip:${KUBE_VIP_VERSION}"
  docker --context "$CTX" push "localhost:${KIND_REGISTRY_PORT}/kube-vip:${KUBE_VIP_VERSION}"
  docker --context "$CTX" pull "ghcr.io/kube-vip/kube-vip-cloud-provider:${KUBE_VIP_CLOUD_PROVIDER_VERSION}"
  docker --context "$CTX" tag "ghcr.io/kube-vip/kube-vip-cloud-provider:${KUBE_VIP_CLOUD_PROVIDER_VERSION}" \
    "localhost:${KIND_REGISTRY_PORT}/kube-vip-cloud-provider:${KUBE_VIP_CLOUD_PROVIDER_VERSION}"
  docker --context "$CTX" push "localhost:${KIND_REGISTRY_PORT}/kube-vip-cloud-provider:${KUBE_VIP_CLOUD_PROVIDER_VERSION}"
  docker --context "$CTX" pull nginx:alpine
  docker --context "$CTX" tag nginx:alpine "localhost:${KIND_REGISTRY_PORT}/door:local"
  docker --context "$CTX" push "localhost:${KIND_REGISTRY_PORT}/door:local"
  echo "---- catalog (in-container; Mac :${KIND_REGISTRY_PORT} may be Desktop's) ----"
  docker --context "$CTX" exec "$KIND_REGISTRY_NAME" wget -qO- http://127.0.0.1:5000/v2/_catalog
  echo
}
export -f push_images
export CTX KIND_REGISTRY_PORT KIND_REGISTRY_NAME KUBE_VIP_VERSION KUBE_VIP_CLOUD_PROVIDER_VERSION
rec bash -c push_images
unset -f push_images

echo "== 4. kube-vip RBAC + cloud-provider + ConfigMap + BGP DS (password set)"
rec kubectl --context "$KCTX" apply \
  -f clusters/eg/kube-vip-rbac.yaml \
  -f clusters/eg/kube-vip-cloud-provider.yaml \
  -f "$HERE/10-kubevip-cm.yaml"
rec kubectl --context "$KCTX" -n kube-system set image \
  deploy/kube-vip-cloud-provider \
  "kube-vip-cloud-provider=localhost:${KIND_REGISTRY_PORT}/kube-vip-cloud-provider:${KUBE_VIP_CLOUD_PROVIDER_VERSION}"
# shellcheck disable=SC2329
render_ds() {
  python3 -c '
import os, pathlib
src = pathlib.Path(os.environ["HERE"]) / "10b-kube-vip-ds-bgp-active-active.yaml"
dst = pathlib.Path(".tmp/kube-vip-ds-bgp-colima.yaml")
dst.parent.mkdir(parents=True, exist_ok=True)
pw = os.environ["FABRIC_BGP_PASSWORD"]
dst.write_text(src.read_text().replace("__BGP_PASSWORD__", pw))
print("rendered %s (password length %d)" % (dst, len(pw)))
'
}
export -f render_ds
export HERE FABRIC_BGP_PASSWORD
rec bash -c render_ds
unset -f render_ds
rec kubectl --context "$KCTX" apply -f .tmp/kube-vip-ds-bgp-colima.yaml
rec kubectl --context "$KCTX" -n kube-system rollout status ds/kube-vip-ds --timeout=180s
rec kubectl --context "$KCTX" -n kube-system wait deploy/kube-vip-cloud-provider \
  --for=condition=Available --timeout=180s

echo "== 5. wait for SERVERS sessions (password on); record MD5"
# shellcheck disable=SC2329
node_ips() {
  local n ip
  for n in $(kind get nodes --name "$EG_COLIMA_CLUSTER"); do
    ip=$(docker --context "$CTX" inspect -f \
      "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" "$n")
    printf '%s\n' "$ip"
  done
}
servers_est() { # leaf → count of Established AS 65021
  local raw
  raw=$(compose_lan exec -T "$1" vtysh -c 'show bgp summary json' 2>&1) || raw=""
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
wait_servers() { # seconds
  local budget=$1 i ok n
  for i in $(seq 1 "$budget"); do
    ok=1
    for leaf in leaf1 leaf2; do
      n=$(servers_est "$leaf")
      if [ "${n:-0}" -lt 2 ]; then
        ok=0
      fi
    done
    if [ "$ok" -eq 1 ]; then
      echo "SERVERS Established on both leaves after ${i}s (2 per leaf)"
      return 0
    fi
    sleep 1
  done
  echo "SERVERS not Established on both leaves after ${budget}s"
  return 1
}
# shellcheck disable=SC2329
session_record() {
  echo "---- node IPs ----"
  kind get nodes --name "$EG_COLIMA_CLUSTER"
  local n
  for n in $(kind get nodes --name "$EG_COLIMA_CLUSTER"); do
    printf '%s ' "$n"
    docker --context "$CTX" inspect -f \
      "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" "$n"
  done
  echo "---- leaf show bgp summary ----"
  local leaf
  for leaf in leaf1 leaf2; do
    echo "-- $leaf"
    compose_lan exec -T "$leaf" vtysh -c 'show bgp summary'
  done
  echo "---- kube-vip DS logs (BGP / MD5 / sockopt) ----"
  kubectl --context "$KCTX" -n kube-system logs -l app.kubernetes.io/name=kube-vip-ds \
    --tail=-1 --prefix --timestamps 2>/dev/null \
    | grep -iE "bgp|peer|65021|${KIND_EG_COLIMA_LEAF1}|${KIND_EG_COLIMA_LEAF2}|md5|sockopt|protocol not available|setsockopt|tcp_md5" || true
}
export -f compose_lan node_ips servers_est wait_servers session_record
export CTX EG_COLIMA_CLUSTER KIND_EG_COLIMA_NET KIND_EG_COLIMA_LEAF1 KIND_EG_COLIMA_LEAF2 KCTX FABRIC_COLIMA_PROJECT FABRIC_COLIMA_FABRIC
# wait_servers uses COMPOSE_LAN array — run in this shell, record the echo
t0=$(date +%s)
if wait_servers 45; then
  MD5_ON_SPEAKER=1
  echo "sessions Established WITH password on kube-vip"
else
  MD5_ON_SPEAKER=0
  echo "sessions NOT Established with password — recording logs, then leaf-side no password"
fi
echo "rollout-to-wait: $(( $(date +%s) - t0 ))s md5_on_speaker=$MD5_ON_SPEAKER" | tee -a "$TRANSCRIPT"
rec bash -c session_record

if [ "$MD5_ON_SPEAKER" -eq 0 ]; then
  echo "---- leaf-side no neighbor SERVERS password (finding, not a workaround we hide) ----"
  rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" \
    -f "$FABRIC_COLIMA_FABRIC/compose.lan-eg.yaml" \
    exec -T leaf1 vtysh \
    -c 'configure terminal' -c 'router bgp 65101' -c 'no neighbor SERVERS password'
  rec docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" \
    -f "$FABRIC_COLIMA_FABRIC/compose.lan-eg.yaml" \
    exec -T leaf2 vtysh \
    -c 'configure terminal' -c 'router bgp 65102' -c 'no neighbor SERVERS password'
  t1=$(date +%s)
  if wait_servers 45; then
    echo "SERVERS Established after leaf-side no password ($(( $(date +%s) - t1 ))s)"
  else
    echo "apply.sh: SERVERS still not Established after leaf-side no password" >&2
    rec bash -c session_record
    exit 1
  fi
  rec bash -c session_record
fi
printf '%s\n' "$MD5_ON_SPEAKER" >.tmp/demo54c-md5-on-speaker
unset -f wait_servers session_record

echo "== 6. door (LoadBalancer on kube-vip class; no Envoy Gateway)"
rec kubectl --context "$KCTX" apply -f "$HERE/00-namespace.yaml" -f "$HERE/20-door.yaml"
rec kubectl --context "$KCTX" -n door rollout status deploy/door --timeout=180s
# wait for ingress IP
# shellcheck disable=SC2329
wait_door() {
  local i ip
  for i in $(seq 1 60); do
    ip=$(kubectl --context "$KCTX" -n door get svc door \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ "$ip" = "$DOOR_ADDR" ]; then
      echo "door Service ingress=$ip after ${i}s"
      return 0
    fi
    sleep 2
  done
  echo "apply.sh: door ingress is ${ip:-absent}, want $DOOR_ADDR" >&2
  kubectl --context "$KCTX" -n door get svc door -o yaml >&2 || true
  return 1
}
export -f wait_door
export KCTX DOOR_ADDR
rec bash -c wait_door
unset -f wait_door

echo "== 7. wait for ${DOOR_ADDR}/32 in each leaf with a node next hop"
# shellcheck disable=SC2329
node_path_count() {
  python3 -c '
import ipaddress, json, os, sys
NET = ipaddress.ip_network(os.environ["KIND_EG_COLIMA_IP_RANGE"])
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
# shellcheck disable=SC2329
wait_paths() {
  local i n leaf
  for i in $(seq 1 90); do
    ok=1
    for leaf in leaf1 leaf2; do
      raw=$(compose_lan exec -T "$leaf" vtysh -c "show ip bgp ${DOOR_ADDR}/32 json" 2>&1) || raw=""
      n=$(printf '%s' "$raw" | node_path_count)
      if [ "$n" = FAIL ] || [ "${n:-0}" -lt 1 ]; then
        ok=0
      fi
    done
    if [ "$ok" -eq 1 ]; then
      echo "both leaves have a node path for ${DOOR_ADDR}/32 after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "apply.sh: ${DOOR_ADDR}/32 missing a node path after 90s" >&2
  return 1
}
export -f compose_lan node_path_count wait_paths
export DOOR_ADDR CTX FABRIC_COLIMA_PROJECT FABRIC_COLIMA_FABRIC KIND_EG_COLIMA_IP_RANGE
rec bash -c wait_paths
# shellcheck disable=SC2329
rib_record() {
  local leaf
  for leaf in leaf1 leaf2; do
    echo "---- $leaf show ip bgp ${DOOR_ADDR}/32 ----"
    compose_lan exec -T "$leaf" vtysh -c "show ip bgp ${DOOR_ADDR}/32"
  done
}
export -f compose_lan rib_record
export DOOR_ADDR CTX FABRIC_COLIMA_PROJECT FABRIC_COLIMA_FABRIC
rec bash -c rib_record
unset -f wait_paths rib_record

echo "== 7b. node return route 10.200.0.0/16 via leaf1 (Docker isolation)"
# The node's default gateway is the docker bridge (KIND_EG_COLIMA_GATEWAY).
# Return traffic for the company fabric must go back through a leaf;
# otherwise Docker's inter-bridge isolation drops it (measured: client0
# curl_rc=28 until this route; leaf1 wget to the door already worked).
# shellcheck disable=SC2329
node_fabric_route() {
  local n
  for n in $(kind get nodes --name "$EG_COLIMA_CLUSTER"); do
    docker --context "$CTX" exec "$n" ip route replace 10.200.0.0/16 via "$KIND_EG_COLIMA_LEAF1"
    printf '%s ' "$n"
    docker --context "$CTX" exec "$n" ip route show 10.200.0.0/16
  done
}
export -f node_fabric_route
export CTX EG_COLIMA_CLUSTER KIND_EG_COLIMA_LEAF1
rec bash -c node_fabric_route
unset -f node_fabric_route

echo "== 8. client0 reaches the door"
# shellcheck disable=SC2329
client0_door() {
  local rc=0 code
  echo "---- client0 ip route get $DOOR_ADDR ----"
  compose_lan exec -T client0 ip route get "$DOOR_ADDR" || true
  echo "---- client0 curl $DOOR_ADDR ----"
  code=$(compose_lan exec -T client0 curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 "http://${DOOR_ADDR}/" ) || rc=$?
  echo "client0 http://${DOOR_ADDR}/ → ${code} curl_rc=$rc"
}
export -f compose_lan client0_door
export DOOR_ADDR CTX FABRIC_COLIMA_PROJECT FABRIC_COLIMA_FABRIC
rec bash -c client0_door
unset -f client0_door

echo "== 9. VM route + DOCKER-USER accept + the Mac's sudo line (never sudo from a script)"
# Two VM-side pieces, measured 2026-09-20 with a throwaway netns in the VM
# standing in for the Mac: the route alone gives curl_rc=28 — Docker 29's
# FORWARD policy is DROP and DOCKER-FORWARD only accepts traffic that ENTERS
# from a docker bridge — and a DOCKER-USER accept toward the node-LAN bridge
# turns the same curl into 200. The Mac's own route is the operator's.
# shellcheck disable=SC2329
mac_path() {
  set -euo pipefail
  local br addr line rc=0 code
  br=$(fabric_colima_kind_bridge)
  echo "VM:  ip route replace $EG_COLIMA_VIP_BLOCK via $KIND_EG_COLIMA_LEAF1"
  echo "VM:  iptables -I DOCKER-USER -d $EG_COLIMA_VIP_BLOCK -o $br -j ACCEPT"
  colima ssh --profile "$FABRIC_COLIMA_PROFILE" -- sudo sh -c "
    ip route replace $EG_COLIMA_VIP_BLOCK via $KIND_EG_COLIMA_LEAF1 \
    && { iptables -C DOCKER-USER -d $EG_COLIMA_VIP_BLOCK -o $br -j ACCEPT 2>/dev/null \
         || iptables -I DOCKER-USER -d $EG_COLIMA_VIP_BLOCK -o $br -j ACCEPT; } \
    && ip route show $EG_COLIMA_VIP_BLOCK && iptables -S DOCKER-USER"
  echo "VM route + DOCKER-USER accept installed"
  addr=$(fabric_colima_vm_address)
  if [ -z "$addr" ]; then
    echo "Mac: profile $FABRIC_COLIMA_PROFILE has no reachable address (network.address: false) — no Mac route can reach this VM yet."
    echo "Mac: enable it, then re-run this apply:"
    echo "  colima stop --profile $FABRIC_COLIMA_PROFILE && colima start --profile $FABRIC_COLIMA_PROFILE --network-address --activate=false"
    return 0
  fi
  echo "Mac: sudo route -n add -net $EG_COLIMA_VIP_BLOCK $addr"
  echo "Mac: sudo route -n delete -net 10.98.0.0/24   # old shared block; Desktop keeps it"
  line=$(netstat -rn -f inet | grep -E '^10\.198' || true)
  if [ -z "$line" ]; then
    echo "Mac route absent — the operator runs:"
    echo "  sudo route -n add -net $EG_COLIMA_VIP_BLOCK $addr"
    echo "  sudo route -n delete -net 10.98.0.0/24"
    return 0
  fi
  echo "Mac route in place:"
  printf '%s\n' "$line"
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    "http://${DOOR_ADDR}/") || rc=$?
  echo "mac http://${DOOR_ADDR}/ → ${code} curl_rc=$rc"
}
export -f mac_path fabric_colima_vm_address fabric_colima_kind_bridge dk
export CTX DOOR_ADDR FABRIC_COLIMA_PROFILE KIND_EG_COLIMA_NET EG_COLIMA_VIP_BLOCK KIND_EG_COLIMA_LEAF1
rec bash -c mac_path
unset -f mac_path

echo "== 10. dashboard /api/state"
rec curl -sS --max-time 5 "${DASH}/api/state"
# shellcheck disable=SC2329
state_head() {
  curl -sS --max-time 5 "${DASH}/api/state" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("routers %s/%s · fabric sessions %s/%s · server sessions %s/%s · external %s" % (
    data.get("reachable"), data.get("routerCount"),
    data.get("established"), data.get("sessionCount"),
    data.get("serverEstablished"), data.get("serverSessions"),
    data.get("external")))
print("external peers:")
for n in data.get("nodes") or []:
    if n.get("kind") == "external":
        print("  %s asn=%s addr=%s" % (n.get("id"), n.get("asn"), n.get("addr")))
'
}
export -f state_head
export DASH
rec bash -c state_head
unset -f state_head
rec bash -c "curl -fsS --max-time 5 '${DASH}/api/state' | python3 scripts/fabric-dashboard-state.py"

echo "== 11. screenshot, dashboard with the cluster attached"
# shellcheck disable=SC1091
. demos/shared/browser-shot.sh
# shellcheck disable=SC2329
shot_dash() {
  mkdir -p "$PWD/$HERE/output/screenshots"
  BROWSER_SHOT_PATH="$PWD/$HERE/output/screenshots/dashboard-cluster.png"
  BROWSER_SHOT_URL="${DASH}/?router=leaf1"
  BROWSER_SHOT_WIDTH=1200
  BROWSER_SHOT_HEIGHT=700
  BROWSER_SHOT_VIRTUAL_TIME_MS=4000
  BROWSER_SHOT_FILE_LABEL="$HERE/output/screenshots/dashboard-cluster.png"
  export BROWSER_SHOT_PATH BROWSER_SHOT_URL BROWSER_SHOT_WIDTH BROWSER_SHOT_HEIGHT BROWSER_SHOT_VIRTUAL_TIME_MS BROWSER_SHOT_FILE_LABEL
  browser_shot
}
export -f shot_dash browser_shot
export CHROME HERE DASH BROWSER_SHOT_PATH BROWSER_SHOT_URL BROWSER_SHOT_WIDTH BROWSER_SHOT_HEIGHT BROWSER_SHOT_VIRTUAL_TIME_MS BROWSER_SHOT_FILE_LABEL
rec bash -c shot_dash
unset -f shot_dash browser_shot

echo "== 12. MD5 evidence on the SERVERS sessions"
# shellcheck disable=SC2329
md5_wire() {
  set -euo pipefail
  cid=$(docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" ps -q leaf1)
  echo "leaf1 container=$cid"
  docker --context "$CTX" run --rm --net "container:${cid}" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    "$NETSHOOT_IMAGE" \
    timeout 15 tcpdump -nn -v -c 20 -i any "tcp port 179 and (host ${KIND_EG_COLIMA_LEAF1})" || true
  # The MD5 counters are per network namespace: the leaf's sessions live in the
  # leaf's netns, so they are read there — the VM's root netns says nothing
  # about them (both were 0 on 2026-09-20; only the leaf's climbs on a bad key).
  echo "---- leaf1 netns TcpExtTCPMD5 counters ----"
  docker --context "$CTX" run --rm --net "container:${cid}" "$NETSHOOT_IMAGE" \
    sh -c 'nstat -az 2>/dev/null | grep -E "TcpExtTCPMD5"'
}
export -f md5_wire
export CTX FABRIC_COLIMA_PROJECT FABRIC_COLIMA_FABRIC NETSHOOT_IMAGE KIND_EG_COLIMA_LEAF1
rec bash -c md5_wire
unset -f md5_wire

echo "dashboard: ${DASH}/ (Mac browser)"
if addr=$(fabric_colima_vm_address) && [ -n "$addr" ]; then
  echo "Mac route (operator): sudo route -n add -net $EG_COLIMA_VIP_BLOCK $addr"
  echo "Mac route (operator): sudo route -n delete -net 10.98.0.0/24"
else
  echo "Mac route: none possible until the profile has a reachable address (see step 9)"
fi
echo "demo 54c apply: recorded"
