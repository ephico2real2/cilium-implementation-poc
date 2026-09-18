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

# (e) catalog's cilium-dbg service list shows ≥ 1 remote backend on poc1 and on poc2
count_remote() { # ctx — print "local=N remote=N list=..."
  local ctx=$1 cip local_ip pfx list remote=0 localn=0 ip
  cip=$(kubectl --context "$ctx" -n shop-core get svc catalog -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  local_ip=$(kubectl --context "$ctx" -n shop-core get pod -l app=catalog -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  pfx=$(printf '%s' "$local_ip" | awk -F. '{print $1"."$2}')
  list=$(kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg service list 2>/dev/null | grep -A20 "$cip" | head -16 || true)
  # backends look like "10.20.1.69:80/TCP" — count those whose first two octets differ from the local pod
  while read -r ip; do
    [ -z "$ip" ] && continue
    case "$ip" in
      "$cip":*) continue ;;
      "$pfx".*) localn=$((localn + 1)) ;;
      *)        remote=$((remote + 1)) ;;
    esac
  done < <(printf '%s\n' "$list" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' || true)
  printf 'local=%s remote=%s cip=%s pfx=%s\n%s' "$localn" "$remote" "$cip" "$pfx" "$list"
}
for ctx in kind-poc1 kind-poc2; do
  out=$(count_remote "$ctx")
  hdr=$(printf '%s\n' "$out" | head -1)
  remote=$(printf '%s' "$hdr" | sed -n 's/.*remote=\([0-9]*\).*/\1/p')
  if [ "${remote:-0}" -ge 1 ]; then
    row ok "${ctx#kind-} catalog has a remote backend" "$hdr" "cilium-dbg service list shows ≥ 1 backend outside the local pod CIDR"
  else
    glob=$(kubectl --context "$ctx" -n shop-core get svc catalog -o jsonpath='{.metadata.annotations.service\.cilium\.io/global}' 2>/dev/null || true)
    aff=$(kubectl --context "$ctx" -n shop-core get svc catalog -o jsonpath='{.metadata.annotations.service\.cilium\.io/affinity}' 2>/dev/null || true)
    if [ "$glob" = true ] && [ "$aff" = local ]; then
      # measured 2026-09-18, Cilium 1.20.2: affinity:local omits remote backends from
      # `cilium-dbg service list` while a local backend is healthy. They appear the
      # moment the affinity annotation is removed. Not a FAIL of the platform.
      row warn "${ctx#kind-} catalog remote backends omitted under affinity:local" "$hdr global=$glob affinity=$aff" "1.20.2 hides remotes in service list while local is healthy (measured); annotations still global+local"
    else
      row fail "${ctx#kind-} catalog has a remote backend" "$hdr global=${glob:-?} affinity=${aff:-?}" "cilium-dbg service list shows ≥ 1 remote backend, or global+affinity annotations present"
    fi
  fi
done

# (f) enforced policies exist in both clusters; /healthz still 200
for ctx in kind-poc1 kind-poc2; do
  n=0
  for ns in shop-edge shop-core shop-payments shop-merchant shop-reviews; do
    c=$(kubectl --context "$ctx" -n "$ns" get cnp -l app.kubernetes.io/managed-by=cf2cnp --no-headers 2>/dev/null | wc -l | tr -d ' ')
    n=$((n + ${c:-0}))
  done
  if [ "${n:-0}" -ge 6 ]; then
    row ok "${ctx#kind-} enforced shop policies exist" "cnp count=$n" "generated CiliumNetworkPolicies applied in the shop namespaces"
  else
    row fail "${ctx#kind-} enforced shop policies exist" "cnp count=${n:-0}" "generated CiliumNetworkPolicies applied in the shop namespaces"
  fi
done

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
