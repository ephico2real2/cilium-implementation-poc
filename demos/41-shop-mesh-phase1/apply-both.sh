#!/usr/bin/env bash
# apply-both.sh — land demo 41 phase 1 on both clusters: the cluster ConfigMap, the platform,
# the HTTPRoutes, the Mac probes, the global-service measurement. Idempotent. Does NOT build
# images (gotcha #118: no docker on the VM while measuring; shopapi:local is already on the nodes).
#
#   demos/41-shop-mesh-phase1/apply-both.sh
#   CONTEXTS="kind-poc1 kind-poc2" demos/41-shop-mesh-phase1/apply-both.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
TRANSCRIPT=demos/41-shop-mesh-phase1/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")"
: > "$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

CONTEXTS="${CONTEXTS:-kind-poc1 kind-poc2}"
# shellcheck disable=SC2206
CTX_ARR=($CONTEXTS)

HERE=demos/41-shop-mesh-phase1
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
SHOP_NS=(shop-edge shop-core shop-payments shop-merchant shop-reviews)

cluster_of() { echo "${1#kind-}"; }

routes_file() {
  case "$1" in
    kind-poc1) echo "$HERE/20-routes-poc1.yaml" ;;
    kind-poc2) echo "$HERE/20-routes-poc2.yaml" ;;
    *) echo "apply-both.sh: no routes file for $1" >&2; return 1 ;;
  esac
}

echo "== 0. no docker build in this phase (gotcha #118). shopapi:local and shopctl are from demo 40."

echo "== 1. remove legacy demo-35 policies only on the first phase-1 transition"
remove_legacy_policies() {
  local ctx=$1 spec ns name
  # backend exists only in the phase-1 generated set. Once it is present, a rerun
  # must preserve the enforced phase-1 policy state.
  if kubectl --context "$ctx" -n shop-core get cnp backend >/dev/null 2>&1; then
    echo "$ctx: phase-1 backend policy present; preserving all shop policies"
    return 0
  fi

  for spec in \
    shop-edge/api-gateway shop-edge/default-deny-ingress \
    shop-core/catalog shop-core/orders shop-core/default-deny-ingress \
    shop-payments/payment-gateway shop-payments/default-deny-ingress \
    shop-merchant/merchant shop-merchant/default-deny-ingress \
    shop-reviews/reviews shop-reviews/default-deny-ingress; do
    ns=${spec%%/*}
    name=${spec##*/}
    if kubectl --context "$ctx" get ns "$ns" >/dev/null 2>&1; then
      rec kubectl --context "$ctx" -n "$ns" delete ciliumnetworkpolicy "$name" \
        --ignore-not-found
    fi
  done
}
for ctx in "${CTX_ARR[@]}"; do
  remove_legacy_policies "$ctx"
done

echo "== 2. ConfigMap/shop-cluster (the only per-cluster value), then the byte-identical platform"
mkdir -p "$HERE/output"
for ctx in "${CTX_ARR[@]}"; do
  c=$(cluster_of "$ctx")
  cm="$HERE/output/shop-cluster-$c.yaml"
  cat > "$cm" <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: shop-core, labels: {app.kubernetes.io/part-of: shop}}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: shop-cluster, namespace: shop-core}
data: {name: $c}
EOF
  rec kubectl --context "$ctx" apply -f "$cm"
  rec kubectl --context "$ctx" apply -f "$HERE/10-platform.yaml"
done

echo "== 3. wait for every Deployment Available (≤ 180s)"
for ctx in "${CTX_ARR[@]}"; do
  for spec in "${DEPLOYS[@]}"; do
    ns=${spec%%/*}; name=${spec##*/}
    rec kubectl --context "$ctx" -n "$ns" wait deploy/"$name" --for=condition=Available --timeout=180s
  done
  rec kubectl --context "$ctx" -n shop-clients wait pod/shopper --for=condition=Ready --timeout=180s
done

echo "== 4. HTTPRoutes (per-cluster files, demo 40's choice)"
for ctx in "${CTX_ARR[@]}"; do
  rec kubectl --context "$ctx" apply -f "$(routes_file "$ctx")"
done

echo "== 5. wait for HTTPRoutes Accepted+ResolvedRefs on both doors (≤ 120s)"
wait_route() {
  local ctx=$1 name=$2 i json
  for i in $(seq 1 24); do
    json=$(kubectl --context "$ctx" -n shop-edge get httproute "$name" -o json 2>/dev/null || true)
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
      echo "$ctx httproute/$name: all parents Accepted+ResolvedRefs"
      return 0
    fi
    sleep 5
  done
  echo "$ctx httproute/$name: NOT ready after 120s" >&2
  kubectl --context "$ctx" -n shop-edge get httproute "$name" -o yaml >&2 || true
  return 1
}
export -f wait_route
for ctx in "${CTX_ARR[@]}"; do
  rec bash -c 'wait_route "$@"' bash "$ctx" shop-api
  rec bash -c 'wait_route "$@"' bash "$ctx" shop-redirect
done
unset -f wait_route

echo "== 6. hosts-entries.sh (the four names; this script never writes /etc/hosts)"
rec demos/40-shop-mesh-phase0/hosts-entries.sh

echo "== 7. probe the three doors from the Mac (curl --resolve; expect 200 and X-Served-By)"
probe_door() {
  local host=$1 addr=$2
  curl -sk --resolve "$host:443:$addr" "https://$host/" -D - -o /dev/null --connect-timeout 5 --max-time 15
}
export -f probe_door
rec bash -c 'probe_door "$@"' bash api.shop.poc.local "$VIP"
rec bash -c 'probe_door "$@"' bash api.poc1.shop.poc.local "$POC1_GW"
rec bash -c 'probe_door "$@"' bash api.poc2.shop.poc.local "$POC2_GW"
unset -f probe_door

echo "== 8. measure global services: shopper → catalog ClusterIP, then cilium-dbg (statedb + bpf lb)"
# Under enforced phase-1 policy shopper is not a catalog caller (it goes through api-gateway).
# The wget is kept as the measurement; it must not abort the rest of the run.
rec kubectl --context kind-poc1 -n shop-clients exec shopper -- wget -qO- --timeout=5 http://catalog.shop-core.svc.cluster.local/healthz || true
echo
show_svc() {
  local ctx=$1
  local cip json nlocal nremote
  cip=$(kubectl --context "$ctx" -n shop-core get svc catalog -o jsonpath='{.spec.clusterIP}')
  echo "-- $ctx catalog ClusterIP=$cip"
  echo "-- annotations global=$(kubectl --context "$ctx" -n shop-core get svc catalog -o jsonpath='{.metadata.annotations.service\.cilium\.io/global}') affinity=$(kubectl --context "$ctx" -n shop-core get svc catalog -o jsonpath='{.metadata.annotations.service\.cilium\.io/affinity}')"
  echo "-- cilium-dbg service list"
  kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg service list 2>/dev/null | grep -A8 "$cip" | head -10
  echo "-- cilium-dbg service list -o json (backend IPs, preferred, state)"
  kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg service list -o json 2>/dev/null | python3 -c '
import json,sys
want="'"$cip"'"
for s in json.load(sys.stdin):
    fe=(s.get("spec") or {}).get("frontend-address") or {}
    if fe.get("ip")==want and fe.get("port")==80:
        flags=(s.get("spec") or {}).get("flags") or {}
        print("flags:", flags)
        for b in (s.get("spec") or {}).get("backend-addresses") or []:
            print(" backend", b.get("ip"), "state="+str(b.get("state")), "preferred="+str(b.get("preferred")))
        n=len((s.get("spec") or {}).get("backend-addresses") or [])
        if n<=1:
            print("MEASURED: realized frontend has the selected local backend only; remote ClusterMesh backends stay in statedb (pkg/clustermesh/selectbackends.go).")
        break
'
  echo "-- cilium-dbg bpf lb list (no affinity column on 1.20.2; flags are [ClusterIP, non-routable])"
  kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg bpf lb list 2>/dev/null | grep "$cip" || true
}
export -f show_svc
rec bash -c 'show_svc "$@"' bash kind-poc1
rec bash -c 'show_svc "$@"' bash kind-poc2
unset -f show_svc

echo "== 9. final table: cluster, deployments available/desired, HTTPRoutes accepted, three probes"
final_table() {
  local ctx c ns name avail des acc res vip_code vip_hdr d242_code d242_hdr d177_code d177_hdr
  header_of() { # host addr — print STATUS|X-Served-By (HTTP/2 lower-case, strip CR)
    local host=$1 addr=$2 hdr code served
    hdr=$(curl -sk --resolve "$host:443:$addr" "https://$host/" -D - -o /dev/null --connect-timeout 5 --max-time 10 2>/dev/null || true)
    hdr=$(printf '%s' "$hdr" | tr -d '\r')
    code=$(printf '%s' "$hdr" | awk 'BEGIN{c="000"} NR==1 && /HTTP/{c=$2} END{print c}')
    served=$(printf '%s' "$hdr" | awk '
      tolower($0) ~ /^[[:space:]]*x-served-by:[[:space:]]*/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        gsub(/[[:space:]]+$/, "")
        print
        exit
      }')
    printf '%s|%s' "${code:-000}" "${served:--}"
  }
  vip_pair=$(header_of api.shop.poc.local 172.18.255.16)
  d242_pair=$(header_of api.poc1.shop.poc.local 172.18.255.242)
  d177_pair=$(header_of api.poc2.shop.poc.local 172.18.255.177)
  vip_code=${vip_pair%%|*}; vip_hdr=${vip_pair#*|}
  d242_code=${d242_pair%%|*}; d242_hdr=${d242_pair#*|}
  d177_code=${d177_pair%%|*}; d177_hdr=${d177_pair#*|}

  printf '%-8s %-14s %-22s %-28s %-28s %-28s\n' \
    CLUSTER DEPLOYMENTS HTTPROUTES VIP POC1_DOOR POC2_DOOR
  for ctx in "$@"; do
    c=${ctx#kind-}
    avail=0; des=0
    for spec in shop-edge/api-gateway shop-core/catalog shop-core/orders shop-core/backend \
                shop-payments/payment-gateway shop-merchant/merchant shop-reviews/reviews; do
      ns=${spec%%/*}; name=${spec##*/}
      a=$(kubectl --context "$ctx" -n "$ns" get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
      d=$(kubectl --context "$ctx" -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
      avail=$((avail + ${a:-0}))
      des=$((des + ${d:-0}))
    done
    acc=$(kubectl --context "$ctx" -n shop-edge get httproute shop-api -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
ps=d.get("status",{}).get("parents") or []
ok=sum(1 for p in ps if {c["type"]:c["status"] for c in p.get("conditions") or []}.get("Accepted")=="True")
print(f"{ok}/{len(ps)} accepted")
' 2>/dev/null || echo '?')
    res=$(kubectl --context "$ctx" -n shop-edge get httproute shop-api -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
ps=d.get("status",{}).get("parents") or []
ok=sum(1 for p in ps if {c["type"]:c["status"] for c in p.get("conditions") or []}.get("ResolvedRefs")=="True")
print(f"{ok}/{len(ps)} resolved")
' 2>/dev/null || echo '?')
    printf '%-8s %-14s %-22s %-28s %-28s %-28s\n' \
      "$c" "${avail}/${des}" "${acc}, ${res}" \
      "${vip_code} X-Served-By=${vip_hdr}" \
      "${d242_code} X-Served-By=${d242_hdr}" \
      "${d177_code} X-Served-By=${d177_hdr}"
  done
}
export -f final_table
rec bash -c 'final_table "$@"' bash "${CTX_ARR[@]}"
unset -f final_table

echo "== 10. check.sh (PASS/FAIL rows; exit is FAIL count)"
rec "$HERE/check.sh" || true
