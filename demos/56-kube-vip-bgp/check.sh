#!/usr/bin/env bash
# check.sh — demo 56 PASS/FAIL rows (demo 54's row() style). Exit = FAIL count.
# At most 18 rows. A failed docker/kubectl/vtysh is a FAIL, never a PASS.
#   demos/56-kube-vip-bgp/check.sh
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

CTX=kind-eg-poc1
CA=.tmp/eg-poc1-root-ca.crt
KV_CLASS=kube-vip.io/kube-vip-class
HTTP_ADDR=10.98.0.10
GRPC_ADDR=10.98.0.11
L2_HTTP=172.19.255.100
HTTP_HOST=api.eg-poc1.poc.local
GRPC_HOST=grpc.eg-poc1.poc.local
CLIENT=bgp-fabric-client0-1
FABRIC=demos/46-bgp-fabric/fabric
PROJECT=bgp-fabric
COMPOSE=(docker compose -p "$PROJECT" -f "$FABRIC/compose.yaml" -f "$FABRIC/compose.lan-eg.yaml")

printf '\n== demo 56 — kube-vip BGP on eg-poc1 (migration from L2)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# 1. kube-vip DS ready with the BGP env
ds_out=$(kubectl --context "$CTX" -n kube-system get ds kube-vip-ds \
  -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>&1)
ds_rc=$?
bgp_en=$(kubectl --context "$CTX" -n kube-system get ds kube-vip-ds \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="bgp_enable")].value}' 2>&1)
bgp_en_rc=$?
bgp_as=$(kubectl --context "$CTX" -n kube-system get ds kube-vip-ds \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="bgp_as")].value}' 2>&1)
bgp_as_rc=$?
if [ "$ds_rc" -ne 0 ] || [ "$bgp_en_rc" -ne 0 ] || [ "$bgp_as_rc" -ne 0 ]; then
  row fail "kube-vip DS ready with BGP env" \
    "kubectl failed ds_rc=$ds_rc env_rc=$bgp_en_rc as_rc=$bgp_as_rc" \
    "10b — ready N/N, bgp_enable=true, bgp_as=65021"
elif printf '%s' "$ds_out" | grep -Eq '^[0-9]+/[0-9]+$' \
  && [ "${ds_out%%/*}" = "${ds_out#*/}" ] && [ "${ds_out%%/*}" -gt 0 ] \
  && [ "$bgp_en" = true ] && [ "$bgp_as" = 65021 ]; then
  row ok "kube-vip DS ready with BGP env" \
    "ready=$ds_out bgp_enable=$bgp_en bgp_as=$bgp_as" \
    "10b — ready N/N, bgp_enable=true, bgp_as=65021"
else
  row fail "kube-vip DS ready with BGP env" \
    "ready=${ds_out:-absent} bgp_enable=${bgp_en:-?} bgp_as=${bgp_as:-?}" \
    "10b — ready N/N, bgp_enable=true, bgp_as=65021"
fi

# 2. 4 sessions Established (both nodes × both leaves)
node_ips=""
for n in $(kind get nodes --name eg-poc1 2>/dev/null); do
  ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind-eg").IPAddress}}' "$n" 2>/dev/null || true)
  if [ -n "$ip" ]; then
    node_ips="$node_ips $ip"
  fi
done
node_ips=${node_ips# }
sess_ok=1
sess_msg=""
if [ -z "$node_ips" ]; then
  sess_ok=0
  sess_msg="no node IPs (kind/docker failed)"
else
  n_est=0
  n_want=0
  for leaf in leaf1 leaf2; do
    raw=$("${COMPOSE[@]}" exec -T "$leaf" vtysh -c 'show bgp summary json' 2>&1) || raw=""
    if [ -z "$raw" ]; then
      sess_ok=0
      sess_msg="${sess_msg}${leaf}:vtysh-fail "
      continue
    fi
    for ip in $node_ips; do
      n_want=$((n_want + 1))
      if printf '%s' "$raw" | python3 scripts/fabric-bgp-summary.py --require "$ip" >/dev/null 2>&1; then
        n_est=$((n_est + 1))
      else
        sess_ok=0
        sess_msg="${sess_msg}${leaf}:$ip "
      fi
    done
  done
  if [ "$n_want" -ne 4 ]; then
    sess_ok=0
    sess_msg="${sess_msg}want=4 got_slots=$n_want "
  fi
fi
if [ "$sess_ok" -eq 1 ]; then
  row ok "4 SERVERS sessions Established" "4/4 Established ($node_ips)" \
    "both nodes × both leaves — JSON state == Established"
else
  row fail "4 SERVERS sessions Established" "${sess_msg:-fail} est=${n_est:-0}" \
    "both nodes × both leaves — JSON state == Established"
fi

# 3–4. leaf1 2 NODE paths for .10 and .11 (nexthop in 172.19.0.0/17).
# A third path from the spine (10.200.1.3) is real BGP and is ignored.
node_path_count() { # prefix → node-path count or FAIL
  local pfx=$1 raw
  raw=$("${COMPOSE[@]}" exec -T leaf1 vtysh -c "show ip bgp ${pfx} json" 2>&1) || raw=""
  if [ -z "$raw" ]; then
    echo FAIL
    return 1
  fi
  printf '%s' "$raw" | python3 -c '
import ipaddress, json, sys
NET = ipaddress.ip_network("172.19.0.0/17")
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("FAIL")
    raise SystemExit(1)
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
    print("FAIL")
    raise SystemExit(1)
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
for pfx in "${HTTP_ADDR}/32" "${GRPC_ADDR}/32"; do
  n=$(node_path_count "$pfx") || n=FAIL
  if [ "$n" = 2 ]; then
    row ok "leaf1 2 node paths for $pfx (both nodes)" "node_paths=$n" \
      "active-active — both nodes advertise to each leaf"
  else
    row fail "leaf1 2 node paths for $pfx (both nodes)" "node_paths=${n:-FAIL}" \
      "active-active — both nodes advertise to each leaf"
  fi
done

# 5–6. door Services class + ingress = the pin + ETP Cluster
expect_door() { # gw want_addr
  local gw=$1 want=$2 json rc=0 klass ingress etp
  json=$(kubectl --context "$CTX" -n envoy-gateway-system get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=$gw" -o json 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    row fail "$gw class + ingress + ETP Cluster" \
      "kubectl failed: $(printf '%s' "$json" | tr '\n' ' ' | head -c 60)" \
      "D11 — class kube-vip, ingress=$want, ETP Cluster"
    return
  fi
  eval "$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("items") or []
except Exception:
    print("klass=?"); print("ingress=?"); print("etp=?"); raise SystemExit
if not items:
    print("klass=missing"); print("ingress=missing"); print("etp=missing"); raise SystemExit
s = items[0]
print("klass=%s" % ((s.get("spec") or {}).get("loadBalancerClass") or "-"))
ings = ((s.get("status") or {}).get("loadBalancer") or {}).get("ingress") or []
print("ingress=%s" % ((ings[0].get("ip") if ings else None) or "-"))
print("etp=%s" % ((s.get("spec") or {}).get("externalTrafficPolicy") or "-"))
' 2>/dev/null)" || { klass=?; ingress=?; etp=?; }
  if [ "$klass" = "$KV_CLASS" ] && [ "$ingress" = "$want" ] && [ "$etp" = Cluster ]; then
    row ok "$gw class + ingress + ETP Cluster" \
      "class=$klass ingress=$ingress etp=$etp" \
      "D11 — class kube-vip, ingress=$want, ETP Cluster"
  else
    row fail "$gw class + ingress + ETP Cluster" \
      "class=${klass:-?} ingress=${ingress:-?} etp=${etp:-?}" \
      "D11 — class kube-vip, ingress=$want, ETP Cluster"
  fi
}
expect_door bgp-http-gw "$HTTP_ADDR"
expect_door bgp-grpc-gw "$GRPC_ADDR"

# Envoy replicas spread: one per node (each BGP door)
envoy_spread() { # gw
  local gw=$1 ready_rc=0 nodes_rc=0 ready= nodes= nuniq
  ready=$(kubectl --context "$CTX" -n envoy-gateway-system get deploy \
    -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
    -o jsonpath='{.items[0].status.readyReplicas}' 2>&1) || ready_rc=$?
  nodes=$(kubectl --context "$CTX" -n envoy-gateway-system get pods \
    -l "gateway.envoyproxy.io/owning-gateway-name=$gw" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>&1) || nodes_rc=$?
  nuniq=$(printf '%s\n' "$nodes" | awk 'NF && !seen[$0]++ {n++} END{print n+0}')
  if [ "$ready_rc" -ne 0 ] || [ "$nodes_rc" -ne 0 ]; then
    row fail "Envoy replicas spread: one per node" \
      "kubectl failed gw=$gw ready_rc=$ready_rc nodes_rc=$nodes_rc" \
      "2 ready Envoy pods, distinct nodeName"
  elif [ "${ready:-0}" -ge 2 ] 2>/dev/null && [ "$nuniq" -ge 2 ]; then
    row ok "Envoy replicas spread: one per node" \
      "$gw ready=$ready nodes=$(printf '%s' "$nodes" | awk 'NF' | sort -u | tr '\n' ',' | sed 's/,$//')" \
      "2 ready Envoy pods, distinct nodeName"
  else
    row fail "Envoy replicas spread: one per node" \
      "$gw ready=${ready:-?} unique_nodes=$nuniq" \
      "2 ready Envoy pods, distinct nodeName"
  fi
}
envoy_spread bgp-http-gw
envoy_spread bgp-grpc-gw

# shopapi replicas spread (2 ready, distinct nodes) AND the rollout complete.
# The ninth run's Deployment had readyReplicas=2 from demo 54's old ReplicaSet
# while 41-shopapi-ha.yaml's pod sat Pending (anti-affinity deadlock): a PASS
# here must mean the anti-affinity template is what is running —
# status.updatedReplicas == status.replicas == spec.replicas.
shopapi_spread() {
  local st_rc=0 nodes_rc=0 st= nodes= nuniq want ready updated total
  st=$(kubectl --context "$CTX" -n shop get deploy shopapi \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.status.updatedReplicas} {.status.replicas}' 2>&1) || st_rc=$?
  nodes=$(kubectl --context "$CTX" -n shop get pods -l app=shopapi \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>&1) || nodes_rc=$?
  nuniq=$(printf '%s\n' "$nodes" | awk 'NF && !seen[$0]++ {n++} END{print n+0}')
  read -r want ready updated total <<<"$st"
  if [ "$st_rc" -ne 0 ] || [ "$nodes_rc" -ne 0 ]; then
    row fail "shopapi replicas spread + rollout complete" \
      "kubectl failed deploy_rc=$st_rc nodes_rc=$nodes_rc" \
      "2 ready shopapi pods, distinct nodeName, updated == replicas == spec"
  elif [ "${ready:-0}" -ge 2 ] 2>/dev/null && [ "$nuniq" -ge 2 ] \
    && [ -n "${want:-}" ] && [ "${updated:-0}" = "$want" ] && [ "${total:-0}" = "$want" ]; then
    row ok "shopapi replicas spread + rollout complete" \
      "ready=$ready updated=$updated/$want nodes=$(printf '%s' "$nodes" | awk 'NF' | sort -u | tr '\n' ',' | sed 's/,$//')" \
      "2 ready shopapi pods, distinct nodeName, updated == replicas == spec"
  else
    row fail "shopapi replicas spread + rollout complete" \
      "ready=${ready:-?} updated=${updated:-?}/${want:-?} total=${total:-?} unique_nodes=$nuniq" \
      "2 ready shopapi pods, distinct nodeName, updated == replicas == spec"
  fi
}
shopapi_spread

# 7. client0 curl 200 + X-Served-By
http_door() {
  local hdr code served rc=0
  hdr=$(docker exec "$CLIENT" curl -s --resolve "${HTTP_HOST}:80:${HTTP_ADDR}" \
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
  if [ "$rc" -eq 0 ] && [ "$code" = 200 ] && [ "$served" = eg-poc1 ]; then
    row ok "client0 http://${HTTP_HOST} 200 + X-Served-By" \
      "http_code=$code X-Served-By=$served" \
      "R8 — 200 and X-Served-By=eg-poc1 from client0"
  else
    row fail "client0 http://${HTTP_HOST} 200 + X-Served-By" \
      "http_code=${code:-000} X-Served-By=${served:-absent} curl_rc=$rc" \
      "R8 — 200 and X-Served-By=eg-poc1 from client0"
  fi
}
http_door

# 8–10. client0 gRPC exact judges (demo 52)
grpc_list() {
  local out rc=0
  out=$(docker exec "$CLIENT" grpcurl -plaintext -authority "$GRPC_HOST" \
    "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  if printf '%s' "$out" | payload_ok list v1 "$rc" >/dev/null; then
    row ok "client0 ListOrders v1" "v1 + three rows" \
      "demo 52 T2 — 3 orders version v1 served_by grpcdemo-v1-"
  else
    row fail "client0 ListOrders v1" \
      "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-48) rc=$rc" \
      "demo 52 T2 — 3 orders version v1 served_by grpcdemo-v1-"
  fi
}
grpc_get() {
  local out rc=0
  out=$(docker exec "$CLIENT" grpcurl -plaintext -authority "$GRPC_HOST" \
    -d '{"id":2}' "${GRPC_ADDR}:80" shop.v1.Orders/GetOrder 2>&1) || rc=$?
  if printf '%s' "$out" | payload_ok get v2 "$rc" >/dev/null; then
    row ok "client0 GetOrder v2" "v2" \
      "demo 52 T4 — GetOrder id=2 version v2 served_by grpcdemo-v2-"
  else
    row fail "client0 GetOrder v2" \
      "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-48) rc=$rc" \
      "demo 52 T4 — GetOrder id=2 version v2 served_by grpcdemo-v2-"
  fi
}
grpc_hdr() {
  local out rc=0
  out=$(docker exec "$CLIENT" grpcurl -plaintext -authority "$GRPC_HOST" \
    -H 'x-version: v2' "${GRPC_ADDR}:80" shop.v1.Orders/ListOrders 2>&1) || rc=$?
  if printf '%s' "$out" | payload_ok list v2 "$rc" >/dev/null; then
    row ok "client0 x-version v2" "v2" \
      "demo 52 T5 — x-version v2 → version v2 served_by grpcdemo-v2-"
  else
    row fail "client0 x-version v2" \
      "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-48) rc=$rc" \
      "demo 52 T5 — x-version v2 → version v2 served_by grpcdemo-v2-"
  fi
}
grpc_list
grpc_get
grpc_hdr

# 11. arping 10.98.0.10 → 0 replies (PASS on absence, FAIL on a reply)
arping_none() { # ip label
  local ip=$1 label=$2 out n
  out=$(docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
    arping -b -c 3 -I eth0 "$ip" 2>&1 || true)
  n=$(printf '%s\n' "$out" | grep -c 'Unicast reply' || true)
  if [ "$n" -gt 0 ]; then
    row fail "arping $label $ip → 0 replies" "replies=$n" \
      "$label — nobody ARPs for a routed address / L2 door unannounced"
  elif printf '%s' "$out" | grep -qE '^Received 0 response\(s\)'; then
    row ok "arping $label $ip → 0 replies" "replies=0" \
      "$label — nobody ARPs for a routed address / L2 door unannounced"
  else
    row fail "arping $label $ip → 0 replies" \
      "docker/arping failed: $(printf '%s' "$out" | tr '\n' ' ' | head -c 48)" \
      "$label — nobody ARPs for a routed address / L2 door unannounced"
  fi
}
arping_none "$HTTP_ADDR" "routed door"
# 12. demo 54's L2 doors now unannounced (the honest consequence)
arping_none "$L2_HTTP" "demo 54 L2 door"

# 13. SERVERS-IN sequence 10 (EG-POC1-VIPS + as-path EG-POC1) invoked > 0 — the
# leaf's BGP counters, not the sum of every sequence (eg-poc2's sequence 20 must
# not carry this row).
rm_raw=$("${COMPOSE[@]}" exec -T leaf1 vtysh -c 'show route-map SERVERS-IN json' 2>&1) || rm_raw=""
invoked=$(printf '%s' "$rm_raw" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("FAIL"); raise SystemExit
# FRR 10.5 keys the daemon "bgpd" (measured); the contract stub used "bgp" — accept both
rules = ((((data.get("bgpd") or data.get("bgp")) or {}).get("SERVERS-IN") or {}).get("rules")) or []
for r in rules:
    if r.get("sequenceNumber") == 10:
        m = " ".join(r.get("matchClauses") or [])
        if "EG-POC1-VIPS" in m and "as-path EG-POC1" in m:
            print(int(r.get("invoked") or 0)); raise SystemExit
print("FAIL")
' 2>/dev/null || echo FAIL)
if [ -z "$rm_raw" ] || [ "$invoked" = FAIL ]; then
  row fail "SERVERS-IN seq 10 (EG-POC1-VIPS + as-path EG-POC1) invoked > 0" "vtysh/JSON failed" \
    "sheet row 4 — EG-POC1-VIPS 10.98.0.0/26 ge 32 le 32 + as-path ^65021$"
elif [ "$invoked" -gt 0 ] 2>/dev/null; then
  row ok "SERVERS-IN seq 10 (EG-POC1-VIPS + as-path EG-POC1) invoked > 0" "seq10_invoked=$invoked" \
    "sheet row 4 — EG-POC1-VIPS 10.98.0.0/26 ge 32 le 32 + as-path ^65021$"
else
  row fail "SERVERS-IN seq 10 (EG-POC1-VIPS + as-path EG-POC1) invoked > 0" "seq10_invoked=$invoked" \
    "sheet row 4 — EG-POC1-VIPS 10.98.0.0/26 ge 32 le 32 + as-path ^65021$"
fi

echo
echo "demo 56 check: $fails FAIL"
exit "$fails"
