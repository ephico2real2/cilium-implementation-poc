#!/usr/bin/env bash
# check.sh — demo 54c PASS/FAIL rows. Exit = FAIL count.
# A dead docker/kubectl/vtysh is a FAIL, never a PASS.
#   demos/54-eg-poc1-kube-vip-colima/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env
NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"

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

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi
if ! fabric_colima_require_ctx; then
  exit 1
fi
if ! fabric_colima_kind_env; then
  exit 1
fi

if [ -f "$FABRIC_COLIMA_FABRIC/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$FABRIC_COLIMA_FABRIC/.env"
  set +a
fi
GOOD_PW="${FABRIC_BGP_PASSWORD:-lab-bgp}"

DOOR_ADDR=10.98.0.10
DASH="http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT}"
MAC_GW=192.168.64.3

compose_lan() {
  docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
    -f "$FABRIC_COLIMA_FABRIC/compose.yaml" \
    -f "$FABRIC_COLIMA_FABRIC/compose.lan-eg.yaml" "$@"
}

printf '\n== demo 54c — kind cluster in Colima, kube-vip BGP to the fabric\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# 1. two nodes in 172.19.0.0/17 on kind-eg-colima
nodes_ok=1
nodes_msg=""
node_ips=""
if ! kind get clusters 2>/dev/null | grep -qx "$EG_COLIMA_CLUSTER"; then
  nodes_ok=0
  nodes_msg="kind cluster $EG_COLIMA_CLUSTER absent (kind/docker failed)"
else
  n_count=0
  for n in $(kind get nodes --name "$EG_COLIMA_CLUSTER" 2>/dev/null); do
    ip=$(docker --context "$CTX" inspect -f \
      "{{(index .NetworkSettings.Networks \"$KIND_EG_COLIMA_NET\").IPAddress}}" \
      "$n" 2>/dev/null || true)
    if [ -z "$ip" ] || [ "$ip" = "<no value>" ]; then
      nodes_ok=0
      nodes_msg="${nodes_msg}${n}:not-on-${KIND_EG_COLIMA_NET} "
      continue
    fi
    in_low=$(python3 -c 'import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1])
print("1" if ip in ipaddress.ip_network("172.19.0.0/17") else "0")
' "$ip" 2>/dev/null || echo 0)
    if [ "$in_low" != 1 ]; then
      nodes_ok=0
      nodes_msg="${nodes_msg}${n}:$ip-not-in-/17 "
    else
      n_count=$((n_count + 1))
      node_ips="${node_ips:+$node_ips }$ip"
    fi
  done
  if [ "$n_count" -ne 2 ]; then
    nodes_ok=0
    nodes_msg="${nodes_msg}want=2 got=$n_count "
  fi
fi
if [ "$nodes_ok" -eq 1 ]; then
  row ok "two nodes in 172.19.0.0/17 on $KIND_EG_COLIMA_NET" "$node_ips" \
    "eg-colima-up — InternalIP in the lower /17"
else
  row fail "two nodes in 172.19.0.0/17 on $KIND_EG_COLIMA_NET" \
    "${nodes_msg:-fail}" \
    "eg-colima-up — InternalIP in the lower /17"
fi

# 2. two SERVERS sessions Established per leaf, sourced from the nodes
sess_ok=1
sess_msg=""
n_est=0
if [ -z "$node_ips" ]; then
  sess_ok=0
  sess_msg="no node IPs"
else
  for leaf in leaf1 leaf2; do
    raw=$(compose_lan exec -T "$leaf" vtysh -c 'show bgp summary json' 2>&1) || raw=""
    if [ -z "$raw" ]; then
      sess_ok=0
      sess_msg="${sess_msg}${leaf}:vtysh-fail "
      continue
    fi
    for ip in $node_ips; do
      if printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py --require "$ip" >/dev/null 2>&1; then
        n_est=$((n_est + 1))
      else
        sess_ok=0
        sess_msg="${sess_msg}${leaf}:$ip "
      fi
    done
  done
fi
if [ "$sess_ok" -eq 1 ] && [ "$n_est" -eq 4 ]; then
  row ok "leaves show two SERVERS sessions each (one per node)" \
    "4/4 Established ($node_ips)" \
    "both leaves × both nodes — JSON state == Established"
else
  row fail "leaves show two SERVERS sessions each (one per node)" \
    "${sess_msg:-fail} est=${n_est:-0}" \
    "both leaves × both nodes — JSON state == Established"
fi

# 3. door /32 in each leaf with a node next hop
node_path_count() {
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
hops = []
for p in found:
    for ip in hop_ips(p):
        try:
            if ipaddress.ip_address(ip) in NET:
                n += 1
                hops.append(ip)
                break
        except ValueError:
            continue
print("%s %s" % (n, ",".join(hops)))
'
}
rib_ok=1
rib_msg=""
for leaf in leaf1 leaf2; do
  raw=$(compose_lan exec -T "$leaf" vtysh -c "show ip bgp ${DOOR_ADDR}/32 json" 2>&1) || raw=""
  if [ -z "$raw" ]; then
    rib_ok=0
    rib_msg="${rib_msg}${leaf}:vtysh-fail "
    continue
  fi
  parsed=$(printf '%s' "$raw" | node_path_count) || parsed="FAIL"
  n=${parsed%% *}
  hops=${parsed#* }
  if [ "$n" = FAIL ] || [ "${n:-0}" -lt 1 ]; then
    rib_ok=0
    rib_msg="${rib_msg}${leaf}:paths=${n:-FAIL} "
  else
    rib_msg="${rib_msg}${leaf}:nh=${hops} "
  fi
done
if [ "$rib_ok" -eq 1 ]; then
  row ok "door ${DOOR_ADDR}/32 in each leaf with a node next hop" \
    "$rib_msg" \
    "EG-POC1-VIPS + as-path 65021 — node in 172.19.0.0/17"
else
  row fail "door ${DOOR_ADDR}/32 in each leaf with a node next hop" \
    "$rib_msg" \
    "EG-POC1-VIPS + as-path 65021 — node in 172.19.0.0/17"
fi

# 4. client0 reaches the door
c0_out=""
c0_rc=0
c0_out=$(compose_lan exec -T client0 curl -s -o /dev/null -w '%{http_code}' \
  --connect-timeout 5 --max-time 10 "http://${DOOR_ADDR}/" 2>&1) || c0_rc=$?
if [ "$c0_rc" -eq 0 ] && [ "$c0_out" = 200 ]; then
  row ok "client0 reaches the door" "http_code=$c0_out" \
    "client0 → edge → spine → leaf → node → ${DOOR_ADDR}"
else
  row fail "client0 reaches the door" \
    "http_code=${c0_out:-?} curl_rc=$c0_rc" \
    "client0 → edge → spine → leaf → node → ${DOOR_ADDR}"
fi

# 5. Mac route via 192.168.64.3 — print the sudo line; never run sudo
echo "  Mac: sudo route -n add -net 10.98.0.0/24 ${MAC_GW}"
mac_line=$(netstat -rn | grep -E '^10\.98' || true)
mac_via=$(printf '%s\n' "$mac_line" | awk '{print $2}' | head -1)
if [ -n "$mac_line" ] && [ "$mac_via" = "$MAC_GW" ]; then
  mac_rc=0
  mac_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    "http://${DOOR_ADDR}/" 2>/dev/null) || mac_rc=$?
  if [ "$mac_rc" -eq 0 ] && [ "$mac_code" = 200 ]; then
    row ok "Mac reaches the door over ${MAC_GW}" \
      "route in place http_code=$mac_code" \
      "operator sudo; script never runs it"
  else
    row fail "Mac reaches the door over ${MAC_GW}" \
      "route in place http_code=${mac_code:-?} curl_rc=$mac_rc" \
      "operator sudo; script never runs it"
  fi
elif [ -n "$mac_line" ]; then
  row fail "Mac reaches the door over ${MAC_GW}" \
    "route present via ${mac_via:-?} (want $MAC_GW)" \
    "operator sudo; script never runs it"
else
  row warn "Mac reaches the door over ${MAC_GW}" \
    "route absent — sudo route -n add -net 10.98.0.0/24 ${MAC_GW}" \
    "operator sudo; script never runs it"
fi

# 6. dashboard server sessions + nodes as external peers
dash_raw=""
dash_rc=0
dash_raw=$(curl -fsS --max-time 3 "${DASH}/api/state" 2>&1) || dash_rc=$?
if [ "$dash_rc" -ne 0 ]; then
  row fail "dashboard server sessions and external peers" \
    "curl rc=$dash_rc" \
    "/api/state — the row that answers 8098"
else
  dash_line=$(printf '%s' "$dash_raw" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("server=%s/%s external=%s" % (
    data.get("serverEstablished"), data.get("serverSessions"), data.get("external")))
' 2>/dev/null) || dash_line="parse-fail"
  ext_ok=$(NODE_IPS="$node_ips" printf '%s' "$dash_raw" | python3 -c '
import json, os, sys
data = json.load(sys.stdin)
want = set(os.environ.get("NODE_IPS","").split())
ext = {n.get("addr") or n.get("id") for n in (data.get("nodes") or []) if n.get("kind")=="external"}
se = data.get("serverEstablished")
ss = data.get("serverSessions")
if se != 4 or ss != 4:
    print("want server 4/4 got %s/%s" % (se, ss)); raise SystemExit(1)
missing = want - ext
if missing:
    print("external missing %s" % ",".join(sorted(missing))); raise SystemExit(1)
print("ok")
' 2>&1) || ext_ok="fail"
  if [ "$ext_ok" = ok ]; then
    row ok "dashboard server sessions and external peers" \
      "$dash_line nodes=$node_ips" \
      "/api/state — server 4/4 (both nodes × both leaves), external=2"
  else
    row fail "dashboard server sessions and external peers" \
      "${dash_line}; ${ext_ok}" \
      "/api/state — server 4/4 (both nodes × both leaves), external=2"
  fi
fi

# 7. MD5: signed or not, measured on the wire; negative control if signed
cid=$(docker --context "$CTX" compose -p "$FABRIC_COLIMA_PROJECT" \
  -f "$FABRIC_COLIMA_FABRIC/compose.yaml" ps -q leaf1 2>&1)
cid_rc=$?
if [ "$cid_rc" -ne 0 ] || [ -z "$cid" ]; then
  row fail "SERVERS MD5 on the wire" "docker ps -q leaf1 failed" \
    "signed or unsigned, measured; negative control if signed"
else
  cap=""
  cap_rc=0
  cap=$(docker --context "$CTX" run --rm --net "container:${cid}" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    "$NETSHOOT_IMAGE" \
    timeout 15 tcpdump -nn -v -c 20 -i any \
    'tcp port 179 and (host 172.19.254.11)' 2>&1) || cap_rc=$?
  if [ "$cap_rc" -ne 0 ] && [ "$cap_rc" -ne 124 ]; then
    row fail "SERVERS MD5 on the wire" "tcpdump/docker rc=$cap_rc" \
      "signed or unsigned, measured; negative control if signed"
  else
    md5_n=$(printf '%s\n' "$cap" | grep -ciE 'md5valid|tcp-md5|md5')
    speaker=$(cat .tmp/demo54c-md5-on-speaker 2>/dev/null || echo "?")
    if [ "$md5_n" -gt 0 ]; then
      # negative control: wrong password on one node session
      first_ip=${node_ips%% *}
      mismatch_ok=1
      mismatch_msg=""
      if [ -z "$first_ip" ]; then
        mismatch_ok=0
        mismatch_msg="no node ip"
      else
        compose_lan exec -T leaf1 vtysh \
          -c 'configure terminal' -c 'router bgp 65101' \
          -c "neighbor ${first_ip} password wrong-54c-md5" >/dev/null 2>&1 || true
        compose_lan exec -T leaf1 vtysh -c "clear ip bgp ${first_ip}" >/dev/null 2>&1 || true
        dropped=""
        i=0
        while [ "$i" -lt 20 ]; do
          raw=$(compose_lan exec -T leaf1 vtysh -c 'show bgp summary json' 2>&1) || raw=""
          st=$(printf '%s' "$raw" | python3 -c '
import json, sys
ip = sys.argv[1]
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
' "$first_ip" 2>/dev/null || echo FAIL)
          if [ "$st" != Established ] && [ "$st" != FAIL ]; then
            dropped=$st
            break
          fi
          i=$((i + 1))
          sleep 1
        done
        compose_lan exec -T leaf1 vtysh \
          -c 'configure terminal' -c 'router bgp 65101' \
          -c "neighbor ${first_ip} password ${GOOD_PW}" >/dev/null 2>&1 || true
        compose_lan exec -T leaf1 vtysh -c "clear ip bgp ${first_ip}" >/dev/null 2>&1 || true
        j=0
        back=""
        while [ "$j" -lt 30 ]; do
          raw=$(compose_lan exec -T leaf1 vtysh -c 'show bgp summary json' 2>&1) || raw=""
          st=$(printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py --require "$first_ip" >/dev/null 2>&1 && echo Established || echo down)
          if [ "$st" = Established ]; then
            back=1
            break
          fi
          j=$((j + 1))
          sleep 1
        done
        if [ -n "$dropped" ] && [ -n "$back" ]; then
          mismatch_msg="Established→${dropped}; restored"
        else
          mismatch_ok=0
          mismatch_msg="drop=${dropped:-none} restored=${back:-no}"
        fi
      fi
      if [ "$mismatch_ok" -eq 1 ]; then
        row ok "SERVERS MD5 on the wire (signed)" \
          "md5-option packets=$md5_n; $mismatch_msg" \
          "speaker password set; negative control restored"
      else
        row fail "SERVERS MD5 on the wire (signed)" \
          "md5-option packets=$md5_n; $mismatch_msg" \
          "speaker password set; negative control restored"
      fi
    else
      row fail "SERVERS MD5 on the wire (unsigned)" \
        "md5-option packets=0 speaker_set=${speaker} (leaf no password)" \
        "D6 — unsigned SERVERS is a defect on this kernel; fabric leaf-spine stays signed"
    fi
  fi
fi

echo
echo "demo 54c check: $fails FAIL"
exit "$fails"
