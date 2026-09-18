#!/usr/bin/env bash
# apply.sh — land demo 53 on the Cilium clusters: restore demo 09's app and route
# on poc1 when absent; add poc2's gRPC listener, leaf, app, policy and GRPCRoute.
# Idempotent. No docker build (gotcha #118: routedemo:local is already on the nodes).
#
#   demos/53-grpc-parity/apply.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export RECORD_STRICT=1
HERE=demos/53-grpc-parity
TRANSCRIPT=$HERE/output/transcript.txt
mkdir -p "$(dirname "$TRANSCRIPT")"
touch "$TRANSCRIPT"
printf '\n### %s — idempotent apply run\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >>"$TRANSCRIPT"
rec() { scripts/record.sh "$TRANSCRIPT" "$@"; }

CTX=kind-poc2

echo "== 0. no docker build (gotcha #118). routedemo:local is on the poc2 nodes from demo 09 / lab-images.sh."
echo "== 0b. live root → .tmp/root-ca.crt (docs/root-ca.crt fingerprint differs from clustermesh-root-ca)"
rec scripts/lab-trust.sh export "$CTX"

echo "== 0c. poc1 demo 09 objects (re-measurement). lab-stack.sh applies only 01-gateway.yaml;"
echo "     grpcroute/grpc was measured absent. Restore 02-apps.yaml + 03-routes.yaml so the re-run has a target."
if kubectl --context kind-poc1 -n routes get grpcroute grpc >/dev/null 2>&1; then
  echo "poc1 grpcroute/grpc already present — not re-applied"
else
  rec kubectl --context kind-poc1 apply -f demos/09-routes/02-apps.yaml
  rec kubectl --context kind-poc1 apply -f demos/09-routes/03-routes.yaml
  rec kubectl --context kind-poc1 -n routes wait deploy/grpc --for=condition=Available --timeout=120s
fi

echo "== 1. demo 40's certificate + Gateway on poc2 (grpc-tls Ready ≤ 90s; shop-gw Programmed with 3 listeners)"
rec kubectl --context "$CTX" apply -f demos/40-shop-mesh-phase0/20-certificates.yaml
rec kubectl --context "$CTX" -n shop-edge wait certificate/shop-tls --for=condition=Ready --timeout=90s
rec kubectl --context "$CTX" -n shop-edge wait certificate/grpc-tls --for=condition=Ready --timeout=90s
rec kubectl --context "$CTX" apply -f demos/40-shop-mesh-phase0/30-gateways-poc2.yaml
rec kubectl --context "$CTX" -n shop-edge wait --for=condition=Programmed gateway/shop-gw --timeout=120s

wait_listeners() {
  local i json n a t
  for i in $(seq 1 24); do
    json=$(kubectl --context kind-poc2 -n shop-edge get gateway shop-gw -o json 2>/dev/null || true)
    n=$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ls=d.get("status",{}).get("listeners") or []
ok=sum(1 for l in ls if {c["type"]:c["status"] for c in l.get("conditions") or []}.get("Programmed")=="True")
print(f"{ok}/{len(ls)}")
' 2>/dev/null || echo "0/0")
    a=${n%%/*}; t=${n##*/}
    if [ "$a" = "$t" ] && [ "${t:-0}" = 3 ]; then
      echo "kind-poc2 gateway/shop-gw: $n listeners Programmed"
      return 0
    fi
    sleep 5
  done
  echo "kind-poc2 gateway/shop-gw: ${n:-?} listeners Programmed (want 3/3) after 120s" >&2
  kubectl --context kind-poc2 -n shop-edge get gateway shop-gw -o yaml >&2 || true
  return 1
}
export -f wait_listeners
rec bash -c wait_listeners
unset -f wait_listeners

echo "== 2. grpc Deployment + Service (Available ≤ 120s)"
rec kubectl --context "$CTX" apply -f "$HERE/10-poc2-grpc-app.yaml"
rec kubectl --context "$CTX" -n shop-edge wait deploy/grpc --for=condition=Available --timeout=120s
# CNP/grpc has to realize before Envoy's reserved:ingress is allowed (demo 41 default-deny).
sleep 3

echo "== 3. GRPCRoute (Accepted+ResolvedRefs on both parents ≤ 120s)"
rec kubectl --context "$CTX" apply -f "$HERE/30-poc2-grpcroute.yaml"

wait_route() {
  local i json
  for i in $(seq 1 24); do
    json=$(kubectl --context kind-poc2 -n shop-edge get grpcroute grpc -o json 2>/dev/null || true)
    if printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
parents=d.get("status",{}).get("parents") or []
if len(parents) < 2: sys.exit(1)
for p in parents:
    cond={c["type"]:c["status"] for c in p.get("conditions") or []}
    if cond.get("Accepted")!="True" or cond.get("ResolvedRefs")!="True":
        sys.exit(1)
' 2>/dev/null; then
      echo "kind-poc2 grpcroute/grpc: all parents Accepted+ResolvedRefs"
      return 0
    fi
    sleep 5
  done
  echo "kind-poc2 grpcroute/grpc: NOT ready after 120s" >&2
  kubectl --context kind-poc2 -n shop-edge get grpcroute grpc -o yaml >&2 || true
  return 1
}
export -f wait_route
rec bash -c wait_route
unset -f wait_route

echo "== 4. unmatched-method probe (GUIDE exercise 1 — what Envoy returns when the route does not match)"
unmatched() {
  # grpcurl is expected to fail: the route does not match this service. || true so RECORD_STRICT
  # does not abort apply.sh; the output is the measurement.
  docker run --rm --network kind fullstorydev/grpcurl:latest \
    -plaintext -max-time 10 -authority grpc.poc2.shop.poc.local \
    172.18.255.177:80 routedemo.Echo/DoesNotExist || true
}
export -f unmatched
rec bash -c unmatched
unset -f unmatched

echo "== 5. check.sh (PASS/FAIL rows; a FAIL row fails this script — demo 41's lesson)"
rec "$HERE/check.sh"

echo "== 6. policy-proof.sh — every apply re-proves CNP grpc (reversible delete / Health fail / Hubble DROPPED / re-apply / SERVING)"
rec "$HERE/policy-proof.sh"

echo "== 7. tls-proof.sh — leaf SAN/issuer/fingerprint/dates; live root OK; docs/root-ca.crt failed (issue #60)"
rec "$HERE/tls-proof.sh"
