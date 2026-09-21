#!/usr/bin/env bash
# apply.sh — demo 52c: a SECOND kind cluster in the Colima VM running MetalLB
# in BGP (frr-k8s) mode, peering with both fabric leaves as AS 65022 and
# announcing a door /32 the whole fabric learns. Idempotent.
#
# Demo 52 (Docker Desktop) runs MetalLB in L2 mode. This one is BGP: the
# difference is the whole point, so nothing here is a port of that.
#   demos/52-eg-poc2-metallb-colima/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
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

HERE=demos/52-eg-poc2-metallb-colima
TRANSCRIPT="${DEMO52C_TRANSCRIPT:-$HERE/output/transcript.txt}"
export RECORD_STRICT=1
mkdir -p "$(dirname "$TRANSCRIPT")"

CLUSTER="$EG_COLIMA_CLUSTER"
KCTX="kind-$CLUSTER"
POOL_CIDR=10.198.0.64/26
DOOR=10.198.0.70
MYASN=65022

if ! fabric_colima_refuse_wrong_ctx; then exit 1; fi
if ! fabric_colima_require_ctx; then exit 1; fi
fabric_colima_save_ctx
trap fabric_colima_restore_ctx EXIT

rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }
say() { printf '\n== %s  (%s)\n' "$1" "$(date -u +%H:%M:%SZ)"; }

{
  echo
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) — demo 52c apply"
} >> "$TRANSCRIPT"

say "1. the fabric must be up, with the leaves on the node LAN"
rec bash -c "docker --context $CTX ps --format '{{.Names}}' | grep -c '^bgp-fabric-colima-' | xargs -I{} echo 'fabric containers: {}'"
for leaf in leaf1 leaf2; do
  rec bash -c "docker --context $CTX exec bgp-fabric-colima-$leaf-1 ip -br addr show | grep -o '172\\.20\\.254\\.[0-9]*/[0-9]*' | xargs -I{} echo '$leaf node-LAN {}'"
done

say "2. the second cluster ($CLUSTER)"
# Its own kind config: distinct pod/service CIDRs from eg-poc1-colima, because
# both clusters share this node LAN and both peer with the same two leaves.
EG_COLIMA_CLUSTER="$CLUSTER" \
EG_COLIMA_KUBECONFIG="${EG_COLIMA_KUBECONFIG:-$HOME/.kube/config-$CLUSTER}" \
EG_COLIMA_TRANSCRIPT="$TRANSCRIPT" \
  rec scripts/eg-colima-up.sh
export KUBECONFIG="${EG_COLIMA_KUBECONFIG:-$HOME/.kube/config-$CLUSTER}"
rec kubectl --context "$KCTX" get nodes -o wide

say "3. MetalLB $METALLB_VERSION in frr-k8s mode (speaker.frr is deprecated in 0.16)"
rec helm repo add metallb https://metallb.github.io/metallb --force-update
rec helm upgrade --install metallb metallb/metallb \
  --version "${METALLB_VERSION#v}" -n metallb-system --create-namespace \
  --kube-context "$KCTX" \
  --set speaker.frr.enabled=false \
  --set frrk8s.enabled=true \
  --wait --timeout 8m
rec kubectl --context "$KCTX" -n metallb-system get deploy,ds

say "4. the password the fabric requires"
# The leaves carry `neighbor SERVERS password …`. A speaker that does not sign
# never gets past Connect — the TCP handshake is dropped before BGP is spoken.
# No committed file here holds the password, the same rule frr.conf follows.
PW="${FABRIC_BGP_PASSWORD:-lab-bgp}"
rec bash -c "kubectl --context $KCTX -n metallb-system create secret generic fabric-bgp-password \
  --type=kubernetes.io/basic-auth --from-literal=username=bgp --from-literal=password='$PW' \
  --dry-run=client -o yaml | kubectl --context $KCTX apply -f -"

say "5. the pool, the advertisement and both peers (AS $MYASN -> 65101/65102)"
rec kubectl --context "$KCTX" apply -f "$HERE/10-metallb-bgp.yaml"

say "6. the door on $DOOR, out of $POOL_CIDR"
rec kubectl --context "$KCTX" apply -f "$HERE/20-door.yaml"
rec kubectl --context "$KCTX" -n eg-poc2 rollout status deploy/door --timeout=180s
rec kubectl --context "$KCTX" -n eg-poc2 get svc door -o wide

say "7. the sessions, as the leaves see them"
sleep 15
for leaf in leaf1 leaf2; do
  rec bash -c "docker --context $CTX exec bgp-fabric-colima-$leaf-1 vtysh -c 'show bgp summary json' | python3 -c '
import json,sys
d=json.load(sys.stdin); peers=d.get(\"ipv4Unicast\",{}).get(\"peers\",{})
for ip,p in sorted(peers.items()):
    if p.get(\"remoteAs\")==$MYASN:
        print(\"$leaf %-14s AS%s %-12s pfxRcd=%s\" % (ip, p.get(\"remoteAs\"), p.get(\"state\"), p.get(\"pfxRcd\")))
'"
done

say "8. the /32 through the fabric, and the door from the Mac"
for r in leaf1 spine edge; do
  rec bash -c "docker --context $CTX exec bgp-fabric-colima-$r-1 vtysh -c 'show bgp ipv4 unicast $DOOR/32 json' | python3 -c '
import json,sys
d=json.load(sys.stdin); paths=d.get(\"paths\",[])
outs=[((p.get(\"nexthops\") or [{}])[0].get(\"ip\",\"?\"))+(\"*\" if p.get(\"bestpath\") else \"\") for p in paths]
print(\"$r %d path(s): %s aspath=%s\" % (len(paths), \" \".join(outs), (paths[0].get(\"aspath\") or {}).get(\"string\",\"\") if paths else \"\"))
'"
done
rec bash -c "curl -s -o /dev/null -m 8 -w 'curl http://$DOOR/ -> %{http_code}\n' http://$DOOR/"

echo
echo "demo 52c apply: done. door $DOOR; dashboard http://127.0.0.1:${FABRIC_COLIMA_DASHBOARD_PORT:-8098}" | tee -a "$TRANSCRIPT"
