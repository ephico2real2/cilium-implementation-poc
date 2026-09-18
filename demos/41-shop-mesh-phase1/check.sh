#!/usr/bin/env bash
# check.sh — demo 41 phase 1 PASS/FAIL rows (demo 40's row() style). Exit = FAIL count.
#   demos/41-shop-mesh-phase1/check.sh
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

VIP=172.18.255.16
POC1_GW=172.18.255.242
POC2_GW=172.18.255.177
DEPLOYS=(
  shop-edge/api-gateway
  shop-core/catalog
  shop-core/orders
  shop-core/backend
  shop-payments/payment-gateway
  shop-merchant/merchant
  shop-reviews/reviews
)

printf '\n== demo 41 — the shop platform on the mesh, phase 1 (the platform behind the doors)\n'
printf '  %-6s %-70s %-52s %s\n' STATUS WHAT MEASURED RULE

# (a) every platform Deployment available in both clusters
for ctx in kind-poc1 kind-poc2; do
  for spec in "${DEPLOYS[@]}"; do
    ns=${spec%%/*}; name=${spec##*/}
    avail=$(kubectl --context "$ctx" -n "$ns" get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
    des=$(kubectl --context "$ctx" -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    if [ "${avail:-0}" = "${des:-0}" ] && [ "${des:-0}" -ge 1 ]; then
      row ok "${ctx#kind-}/$ns/$name Available" "${avail}/${des}" "availableReplicas == spec.replicas ≥ 1"
    else
      row fail "${ctx#kind-}/$ns/$name Available" "${avail:-?}/${des:-?}" "availableReplicas == spec.replicas ≥ 1"
    fi
  done
done

# (b) HTTPRoutes Accepted on both doors in both clusters
route_parents() { # ctx name — print "accepted=N/M resolved=N/M"
  kubectl --context "$1" -n shop-edge get httproute "$2" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
ps=d.get("status",{}).get("parents") or []
acc=sum(1 for p in ps if {c["type"]:c["status"] for c in p.get("conditions") or []}.get("Accepted")=="True")
res=sum(1 for p in ps if {c["type"]:c["status"] for c in p.get("conditions") or []}.get("ResolvedRefs")=="True")
print(f"accepted={acc}/{len(ps)} resolved={res}/{len(ps)}")
' 2>/dev/null || echo "accepted=?/? resolved=?/?"
}
for ctx in kind-poc1 kind-poc2; do
  for name in shop-api shop-redirect; do
    m=$(route_parents "$ctx" "$name")
    acc=${m#accepted=}; acc=${acc%% *}; a=${acc%%/*}; t=${acc##*/}
    res=${m##*resolved=}; r=${res%%/*}; rt=${res##*/}
    if [ "$a" = "$t" ] && [ "$r" = "$rt" ] && [ "${t:-0}" -ge 2 ]; then
      row ok "${ctx#kind-}/$name Accepted on both doors" "$m" "every parent Accepted=True and ResolvedRefs=True (≥ 2 parents)"
    else
      row fail "${ctx#kind-}/$name Accepted on both doors" "$m" "every parent Accepted=True and ResolvedRefs=True (≥ 2 parents)"
    fi
  done
done

# (c) VIP → 200 + X-Served-By matching vip-takeover.sh --status (do not hard-code poc1)
announcer=$(scripts/vip-takeover.sh --status 2>/dev/null | awk -F': ' '/announced by:/{print $2; exit}' | tr -d ' ')
announcer=${announcer:-?}
curl_door() { # host addr — print code|served
  local host=$1 addr=$2 hdr code served
  hdr=$(curl -sk --resolve "$host:443:$addr" "https://$host/" -D - -o /dev/null --connect-timeout 5 --max-time 10 2>/dev/null || true)
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  served=$(printf '%s' "$hdr" | awk 'tolower($0) ~ /^x-served-by:/ {print $2}' | tr -d '\r')
  printf '%s|%s' "${code:-000}" "${served}"
}
vip_pair=$(curl_door api.shop.poc.local "$VIP")
vip_code=${vip_pair%%|*}; vip_srv=${vip_pair#*|}
if [ "$vip_code" = 200 ] && [ -n "$vip_srv" ] && [ "$vip_srv" = "$announcer" ]; then
  row ok "VIP https://api.shop.poc.local @ $VIP" "http_code=$vip_code X-Served-By=$vip_srv announcer=$announcer" "200 and X-Served-By equals vip-takeover.sh --status"
elif [ "$vip_code" = 200 ] && [ -n "$vip_srv" ]; then
  row fail "VIP https://api.shop.poc.local @ $VIP" "http_code=$vip_code X-Served-By=$vip_srv announcer=$announcer" "200 and X-Served-By equals vip-takeover.sh --status"
else
  row fail "VIP https://api.shop.poc.local @ $VIP" "http_code=${vip_code:-000} X-Served-By=${vip_srv:-absent} announcer=$announcer" "200 and X-Served-By present"
fi
if [ -z "$vip_srv" ]; then
  row fail "X-Served-By never absent on the VIP" "absent" "the Gateway filter SET the header"
else
  row ok "X-Served-By never absent on the VIP" "X-Served-By=$vip_srv" "the Gateway filter SET the header"
fi

# (d) .242 → 200 + poc1; .177 → 200 + poc2
d242=$(curl_door api.poc1.shop.poc.local "$POC1_GW")
c242=${d242%%|*}; s242=${d242#*|}
if [ "$c242" = 200 ] && [ "$s242" = poc1 ]; then
  row ok "https://api.poc1.shop.poc.local @ $POC1_GW" "http_code=$c242 X-Served-By=$s242" "200 and X-Served-By=poc1"
else
  row fail "https://api.poc1.shop.poc.local @ $POC1_GW" "http_code=${c242:-000} X-Served-By=${s242:-absent}" "200 and X-Served-By=poc1"
fi
d177=$(curl_door api.poc2.shop.poc.local "$POC2_GW")
c177=${d177%%|*}; s177=${d177#*|}
if [ "$c177" = 200 ] && [ "$s177" = poc2 ]; then
  row ok "https://api.poc2.shop.poc.local @ $POC2_GW" "http_code=$c177 X-Served-By=$s177" "200 and X-Served-By=poc2"
else
  row fail "https://api.poc2.shop.poc.local @ $POC2_GW" "http_code=${c177:-000} X-Served-By=${s177:-absent}" "200 and X-Served-By=poc2"
fi

# (d2) :80 with the HTTP Host header → 301 Location https://<host>/ (optional :443)
curl_redirect() { # host addr — print code|location-count|location
  local host=$1 addr=$2 hdr code locations n location
  hdr=$(curl -sS --resolve "$host:80:$addr" "http://$host/" \
    -D - -o /dev/null --connect-timeout 5 --max-time 10 2>/dev/null || true)
  code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
  locations=$(printf '%s' "$hdr" |
    awk 'tolower($0) ~ /^location:/ {sub(/\r$/,""); sub(/^[^:]*:[[:space:]]*/,""); print}')
  n=$(printf '%s\n' "$locations" | grep -c . || true)
  location=$(printf '%s\n' "$locations" | head -1)
  printf '%s|%s|%s' "${code:-000}" "$n" "$location"
}

for spec in \
  "api.shop.poc.local|$VIP" \
  "api.poc1.shop.poc.local|$POC1_GW" \
  "api.poc2.shop.poc.local|$POC2_GW"; do
  host=${spec%%|*}
  addr=${spec#*|}
  got=$(curl_redirect "$host" "$addr")
  code=${got%%|*}
  rest=${got#*|}
  count=${rest%%|*}
  location=${rest#*|}
  loc_ok=0
  case "$location" in
    "https://$host/"*|"https://$host:443/"*) loc_ok=1 ;;
  esac
  if [ "$code" = 301 ] && [ "$count" = 1 ] && [ "$loc_ok" = 1 ]; then
    row ok "http://$host @ $addr redirects" \
      "http_code=$code Location=$location" \
      "301 and exactly one Location beginning https://$host/ (optional :443)"
  else
    row fail "http://$host @ $addr redirects" \
      "http_code=${code:-000} locations=${count:-0} Location=${location:-absent}" \
      "301 and exactly one Location beginning https://$host/ (optional :443)"
  fi
done

# (e) affinity:local — remote backends are known in statedb, not selected in bpf lb
# while a local one is Active (pkg/clustermesh/selectbackends.go).
catalog_backends() { # ctx — print known=N (clustermesh=N) selected=N local|mixed|remote|none
  local ctx=$1 cip local_ips statedb bpf tmp
  cip=$(kubectl --context "$ctx" -n shop-core get svc catalog \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  local_ips=$(kubectl --context "$ctx" -n shop-core get pods -l app=catalog \
    -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}' 2>/dev/null || true)
  statedb=$(kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg statedb backends 2>/dev/null || true)
  bpf=$(kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg bpf lb list -o json 2>/dev/null || true)
  tmp=$(mktemp -d)
  printf '%s' "$statedb" >"$tmp/statedb.json"
  printf '%s' "$bpf" >"$tmp/bpf.json"
  python3 -c '
import json, sys
cip, local_text, statedb_path, bpf_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
local_ips = set(local_text.split())
raw = open(statedb_path).read()
rows = []
try:
    data = json.loads(raw)
    if isinstance(data, dict):
        rows = list(data.get("backends") or [])
    elif isinstance(data, list):
        rows = data
except Exception:
    rows = []
    for line in raw.splitlines():
        s = line.strip().rstrip(",")
        try:
            obj = json.loads(s)
        except Exception:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
cat = [b for b in rows if isinstance(b, dict)
       and b.get("ServiceName") == "shop-core/catalog" and "Source" in b]
known = len(cat)
cm = sum(1 for b in cat if b.get("Source") == "clustermesh")
selected = []
try:
    bpf = json.loads(open(bpf_path).read() or "{}")
except Exception:
    bpf = {}
if isinstance(bpf, dict):
    for key, vals in bpf.items():
        if not str(key).startswith(cip + ":80"):
            continue
        for val in vals or []:
            ip = str(val).split(":")[0].strip()
            if ip and ip != "0.0.0.0":
                selected.append(ip)
seen = set()
sel = []
for ip in selected:
    if ip not in seen:
        seen.add(ip)
        sel.append(ip)
kind = "none"
if sel:
    loc = sum(1 for ip in sel if ip in local_ips)
    if loc == len(sel):
        kind = "local"
    elif loc == 0:
        kind = "remote"
    else:
        kind = "mixed"
print("known=%d (clustermesh=%d) selected=%d %s" % (known, cm, len(sel), kind))
' "$cip" "$local_ips" "$tmp/statedb.json" "$tmp/bpf.json"
  rm -rf "$tmp"
}

for ctx in kind-poc1 kind-poc2; do
  hdr=$(catalog_backends "$ctx")
  known=$(printf '%s' "$hdr" | sed -n 's/.*known=\([0-9]*\).*/\1/p')
  cm=$(printf '%s' "$hdr" | sed -n 's/.*clustermesh=\([0-9]*\).*/\1/p')
  seln=$(printf '%s' "$hdr" | sed -n 's/.*selected=\([0-9]*\).*/\1/p')
  kind=$(printf '%s' "$hdr" | awk '{print $NF}')
  if [ "${known:-0}" -ge 2 ] && [ "${cm:-0}" -ge 1 ] &&
     [ "${seln:-0}" -ge 1 ] && [ "$kind" = local ]; then
    row ok "${ctx#kind-} catalog backends under affinity:local" \
      "$hdr" \
      "affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)"
  else
    row fail "${ctx#kind-} catalog backends under affinity:local" \
      "$hdr" \
      "affinity local — remote backends known, not selected while a local one is Active (pkg/clustermesh/selectbackends.go)"
  fi
done

# BEGIN policy checks
EXPECTED_GENERATED=(
  shop-edge/api-gateway
  shop-core/backend
  shop-core/catalog
  shop-core/orders
  shop-payments/payment-gateway
  shop-merchant/merchant
  shop-reviews/reviews
)
SHOP_ENDPOINTS=(
  shop-edge/api-gateway
  shop-core/backend
  shop-core/catalog
  shop-core/orders
  shop-payments/payment-gateway
  shop-merchant/merchant
  shop-reviews/reviews
  shop-reviews/ratings
)

endpoint_policy_state() { # ctx namespace app-name
  local ctx=$1 ns=$2 app=$3 pod node agent json
  pod=$(kubectl --context "$ctx" -n "$ns" get pod \
    -l "app.kubernetes.io/name=$app" --field-selector status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$pod" ] || { printf 'missing-pod'; return; }
  node=$(kubectl --context "$ctx" -n "$ns" get pod "$pod" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  agent=$(kubectl --context "$ctx" -n kube-system get pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$node" -o name 2>/dev/null | head -1)
  json=$(kubectl --context "$ctx" -n kube-system exec "$agent" -c cilium-agent -- \
    cilium-dbg endpoint get "cep-name:$ns/$pod" -o json 2>/dev/null || true)
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    value=json.load(sys.stdin)
    endpoint=value[0] if isinstance(value,list) else value
    enabled=endpoint["status"]["policy"]["realized"]["policy-enabled"]
    audit=endpoint["status"]["realized"]["options"]["PolicyAuditMode"]
    print(f"{enabled}|{audit}")
except Exception:
    print("unreadable|unreadable")
'
}

check_policies() {
  local ctx expected actual n good spec ns app state enabled audit
  expected=$(printf '%s\n' "${EXPECTED_GENERATED[@]}" | sort)
  for ctx in kind-poc1 kind-poc2; do
    actual=$(kubectl --context "$ctx" get cnp -A \
      -l app.kubernetes.io/managed-by=cf2cnp -o json 2>/dev/null |
      python3 -c '
import json, sys
shop={"shop-edge","shop-core","shop-payments","shop-merchant","shop-reviews"}
try:
    data=json.load(sys.stdin)
except Exception:
    data={"items":[]}
for item in data.get("items",[]):
    ns=item["metadata"].get("namespace","")
    if ns in shop:
        print("{}/{}".format(ns, item["metadata"]["name"]))
' | sort)
    n=$(printf '%s\n' "$actual" | grep -c . || true)
    if [ "$actual" = "$expected" ]; then
      row ok "${ctx#kind-} has exactly the seven generated shop policies" \
        "$n/7 exact names" "exact generated policy inventory, managed-by=cf2cnp"
    else
      row fail "${ctx#kind-} has exactly the seven generated shop policies" \
        "$n/7; actual=$(printf '%s' "$actual" | tr '\n' ',')" \
        "exact generated policy inventory, managed-by=cf2cnp"
      continue
    fi

    good=0
    for spec in "${SHOP_ENDPOINTS[@]}"; do
      ns=${spec%%/*}
      app=${spec##*/}
      state=$(endpoint_policy_state "$ctx" "$ns" "$app")
      enabled=${state%%|*}
      audit=${state#*|}
      case "$enabled|$audit" in
        ingress\|Disabled|both\|Disabled) good=$((good + 1)) ;;
      esac
    done
    if [ "$good" = "${#SHOP_ENDPOINTS[@]}" ]; then
      row ok "${ctx#kind-} shop endpoints enforce ingress policy" \
        "$good/${#SHOP_ENDPOINTS[@]} policy-enabled, PolicyAuditMode=Disabled" \
        "every service endpoint and ratings enforces policy with audit disabled"
    else
      row fail "${ctx#kind-} shop endpoints enforce ingress policy" \
        "$good/${#SHOP_ENDPOINTS[@]} policy-enabled, PolicyAuditMode=Disabled" \
        "every service endpoint and ratings enforces policy with audit disabled"
    fi
  done
}
check_policies
# END policy checks

hz_hdr=$(curl -sk --resolve api.shop.poc.local:443:$VIP https://api.shop.poc.local/healthz -D - -o /dev/null --connect-timeout 5 --max-time 10 2>/dev/null || true)
hz_code=$(printf '%s' "$hz_hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
hz_srv=$(printf '%s' "$hz_hdr" | awk 'tolower($0) ~ /^x-served-by:/ {print $2}' | tr -d '\r')
if [ "$hz_code" = 200 ]; then
  row ok "VIP /healthz still 200 after policies" "http_code=$hz_code X-Served-By=${hz_srv:-absent}" "probe /healthz is 200 with the header"
else
  row fail "VIP /healthz still 200 after policies" "http_code=${hz_code:-000} X-Served-By=${hz_srv:-absent}" "probe /healthz is 200 with the header"
fi
if [ -z "$hz_srv" ]; then
  row fail "X-Served-By never absent on /healthz" "absent" "the Gateway filter SET the header"
else
  row ok "X-Served-By never absent on /healthz" "X-Served-By=$hz_srv" "the Gateway filter SET the header"
fi

exit "$fails"
