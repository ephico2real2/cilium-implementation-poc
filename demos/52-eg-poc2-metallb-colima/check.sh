#!/usr/bin/env bash
# check.sh — demo 52c PASS/FAIL rows. Exit = FAIL count.
# A dead docker/kubectl/vtysh is a FAIL, never a PASS.
#   demos/52-eg-poc2-metallb-colima/check.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# This demo's cluster must be named BEFORE fabric-colima-lib.sh is sourced.
# The library defaults EG_COLIMA_CLUSTER and EG_COLIMA_KUBECONFIG to
# eg-poc1-colima — demo 54c's cluster — so a `${EG_COLIMA_CLUSTER:-...}` after
# the source silently reads poc1 and every in-cluster row reports "absent"
# while the fabric rows pass. Measured 2026-09-21: the check queried
# `--context kind-eg-poc1-colima` and called this lab broken.
: "${EG_COLIMA_CLUSTER:=eg-poc2-colima}"
: "${EG_COLIMA_KUBECONFIG:=$HOME/.kube/config-$EG_COLIMA_CLUSTER}"
export EG_COLIMA_CLUSTER EG_COLIMA_KUBECONFIG
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh
# shellcheck disable=SC1091
. scripts/bootstrap/versions-eg.env

CLUSTER="$EG_COLIMA_CLUSTER"
KCTX="kind-$CLUSTER"
MYASN=65022
DOOR=10.198.0.70
POOL=10.198.0.64/26

fails=0
row() {
  local st
  case "$1" in
    ok)   st=PASS ;;
    fail) st=FAIL; fails=$((fails + 1)) ;;
    warn) st=WARN ;;
    *)    st=$1 ;;
  esac
  printf '  %-6s %-62s %-56s %s\n' "$st" "$2" "$3" "$4"
}

if ! fabric_colima_refuse_wrong_ctx; then exit 1; fi
if ! fabric_colima_require_ctx; then exit 1; fi
# kind and kubectl need the VM's daemon and this cluster's kubeconfig. Without
# it every kubectl row reads "absent" while the fabric rows pass, which looks
# like the cluster is gone rather than like the check is looking in the wrong
# place.
if ! fabric_colima_kind_env; then exit 1; fi
export KUBECONFIG="$EG_COLIMA_KUBECONFIG"

echo "== demo 52c — MetalLB in BGP mode on a second Colima cluster (AS $MYASN)"
printf '  %-6s %-62s %-56s %s\n' STATUS WHAT MEASURED RULE

# 1. two clusters, side by side, on one node LAN
clusters=$(kind get clusters 2>/dev/null | tr '\n' ' ')
if echo "$clusters" | grep -q eg-poc2-colima && echo "$clusters" | grep -q eg-poc1-colima; then
  row ok "both Colima clusters exist" "$clusters" "52c runs beside 54c on $KIND_EG_COLIMA_NET"
else
  row fail "both Colima clusters exist" "${clusters:-none}" "52c runs beside 54c on $KIND_EG_COLIMA_NET"
fi

# 2. distinct pod/service CIDRs — two clusters on one LAN cannot share them
p1=$(grep -A3 '^networking:' clusters/eg-poc1-colima.yaml | grep podSubnet | tr -d ' "' | cut -d: -f2)
p2=$(grep -A6 '^networking:' clusters/eg-poc2-colima.yaml | grep podSubnet | tr -d ' "' | cut -d: -f2)
if [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ]; then
  row ok "the two clusters' pod CIDRs differ" "poc1 $p1 vs poc2 $p2" "one node LAN, two clusters: no shared pod CIDR"
else
  row fail "the two clusters' pod CIDRs differ" "poc1 ${p1:-?} vs poc2 ${p2:-?}" "one node LAN, two clusters: no shared pod CIDR"
fi

# 3. the inotify limit that blocks a second cluster
inst=$(colima ssh --profile "$FABRIC_COLIMA_PROFILE" -- sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
if [ "${inst:-0}" -ge 512 ]; then
  row ok "fs.inotify.max_user_instances raised" "instances=$inst" "128 starts one cluster and fails the second"
else
  row fail "fs.inotify.max_user_instances raised" "instances=${inst:-unreadable}" "128 starts one cluster and fails the second"
fi

# 4. MetalLB is in frr-k8s mode, not the deprecated speaker.frr
frrk8s=$(kubectl --context "$KCTX" -n metallb-system get ds metallb-frr-k8s -o jsonpath='{.status.numberReady}' 2>/dev/null)
if [ "${frrk8s:-0}" -ge 2 ]; then
  row ok "MetalLB running frr-k8s (not the deprecated FRR mode)" "metallb-frr-k8s ready=$frrk8s" "0.16 deprecates speaker.frr.enabled"
else
  row fail "MetalLB running frr-k8s (not the deprecated FRR mode)" "ready=${frrk8s:-none}" "0.16 deprecates speaker.frr.enabled"
fi

# 5. every node peers with BOTH leaves, and the sessions are Established
est=0; total=0
for leaf in leaf1 leaf2; do
  out=$(docker --context "$CTX" exec "bgp-fabric-colima-$leaf-1" vtysh -c 'show bgp summary json' 2>/dev/null \
    | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(1)
peers=d.get('ipv4Unicast',{}).get('peers',{})
mine=[p for p in peers.values() if p.get('remoteAs')==$MYASN]
print('%d %d' % (len(mine), sum(1 for p in mine if p.get('state')=='Established')))
" 2>/dev/null) || out=""
  [ -z "$out" ] && { row fail "leaves show the AS $MYASN sessions" "$leaf: vtysh unreadable" "two nodes x two leaves"; break; }
  total=$((total + ${out% *})); est=$((est + ${out#* }))
done
if [ "$est" -eq 4 ] && [ "$total" -eq 4 ]; then
  row ok "four AS $MYASN sessions Established (2 nodes x 2 leaves)" "$est/4 Established" "two nodes x two leaves"
else
  row fail "four AS $MYASN sessions Established (2 nodes x 2 leaves)" "$est/$total Established" "two nodes x two leaves"
fi

# 6. the sessions are SIGNED — the fabric refuses an unsigned speaker
pw_rows=$(docker --context "$CTX" exec bgp-fabric-colima-leaf1-1 vtysh -c 'show running-config' 2>/dev/null | grep -c 'neighbor SERVERS password')
sec=$(kubectl --context "$KCTX" -n metallb-system get secret fabric-bgp-password -o name 2>/dev/null)
if [ "${pw_rows:-0}" -ge 1 ] && [ -n "$sec" ]; then
  row ok "the sessions are signed (TCP MD5)" "leaf1 requires a password; $sec supplies it" "MetalLB stays in Connect unsigned"
else
  row fail "the sessions are signed (TCP MD5)" "leaf password rows=$pw_rows secret=${sec:-absent}" "MetalLB stays in Connect unsigned"
fi

# 7. the door has its address, and it is inside the pool the fabric permits
ip=$(kubectl --context "$KCTX" -n eg-poc2 get svc door -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ "$ip" = "$DOOR" ]; then
  row ok "the door holds $DOOR from $POOL" "external-ip=$ip" "EG-POC2-VIPS permits $POOL ge 32 le 32"
else
  row fail "the door holds $DOOR from $POOL" "external-ip=${ip:-none}" "EG-POC2-VIPS permits $POOL ge 32 le 32"
fi

# 8. the fabric learned the /32, and the spine has BOTH paths
spine_paths=$(docker --context "$CTX" exec bgp-fabric-colima-spine-1 vtysh -c "show bgp ipv4 unicast $DOOR/32 json" 2>/dev/null \
  | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('paths',[])))" 2>/dev/null)
if [ "${spine_paths:-0}" -ge 2 ]; then
  row ok "spine has two paths to $DOOR (one per leaf)" "paths=$spine_paths" "ECMP: a leaf may be lost"
else
  row fail "spine has two paths to $DOOR (one per leaf)" "paths=${spine_paths:-0}" "ECMP: a leaf may be lost"
fi

# 9. the as-path the edge sees proves it came the whole way
aspath=$(docker --context "$CTX" exec bgp-fabric-colima-edge-1 vtysh -c "show bgp ipv4 unicast $DOOR/32 json" 2>/dev/null \
  | python3 -c "
import json,sys
p=json.load(sys.stdin).get('paths',[])
print((p[0].get('aspath') or {}).get('string','') if p else '')
" 2>/dev/null)
if [ "$aspath" = "65100 65101 65022" ] || [ "$aspath" = "65100 65102 65022" ]; then
  row ok "the edge sees it via the whole fabric" "aspath=$aspath" "spine, a leaf, then the cluster"
else
  row fail "the edge sees it via the whole fabric" "aspath=${aspath:-absent}" "spine, a leaf, then the cluster"
fi

# 10. the door answers from the Mac, through the fabric
code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$DOOR/" 2>/dev/null)
if [ "$code" = "200" ]; then
  row ok "the door answers from the Mac" "curl http://$DOOR/ -> $code" "route via the Colima VM address"
else
  row fail "the door answers from the Mac" "curl http://$DOOR/ -> ${code:-000}" "route via the Colima VM address"
fi

# 11. a prefix OUTSIDE the cluster's range is not accepted — the filter is real
denied=$(docker --context "$CTX" exec bgp-fabric-colima-leaf1-1 vtysh -c 'show running-config' 2>/dev/null \
  | grep -c 'ip prefix-list EG-POC2-VIPS seq 10 permit 10.198.0.64/26 ge 32 le 32')
if [ "${denied:-0}" -ge 1 ]; then
  row ok "the leaf filters this cluster to its own /26" "EG-POC2-VIPS 10.198.0.64/26 ge 32 le 32" "a cluster may not announce another's range"
else
  row fail "the leaf filters this cluster to its own /26" "prefix-list absent" "a cluster may not announce another's range"
fi

echo
echo "demo 52c check: $fails FAIL"
exit "$fails"
