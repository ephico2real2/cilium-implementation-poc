#!/usr/bin/env bash
# policy-proof.sh — reversible proof that CNP grpc is what lets reserved:ingress
# (identity 8) reach grpc:9090. Delete the CNP → Health/Check from the grpcurl
# client container fails → Hubble compact shows Policy denied DROPPED from
# (ingress) identity 8 → re-apply 10-poc2-grpc-app.yaml → SERVING again.
# Exit non-zero if any step's expectation is not met. apply.sh records this
# after check.sh, so every apply re-proves the policy.
#
#   demos/53-grpc-parity/policy-proof.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

CTX=kind-poc2
NS=shop-edge
HOST=grpc.poc2.shop.poc.local
GW=172.18.255.177
APP=demos/53-grpc-parity/10-poc2-grpc-app.yaml

grpcurl_health() {
  docker run --rm --network kind fullstorydev/grpcurl:latest \
    -plaintext -max-time 10 -authority "$HOST" \
    "$GW:80" grpc.health.v1.Health/Check 2>&1 || true
}

is_serving() {
  printf '%s' "$1" | tr -d '[:space:]' | grep -q '"status":"SERVING"'
}

die() {
  printf 'policy-proof: %s\n' "$1" >&2
  exit 1
}

pod=$(kubectl --context "$CTX" -n "$NS" get pod -l app=grpc \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$pod" ] || die "no grpc pod in $NS"

restore() {
  echo "== restore: re-apply $APP"
  kubectl --context "$CTX" apply -f "$APP" || true
}
trap restore EXIT

echo "== 1. delete CNP grpc in $NS on poc2 (demo 41 default-deny then drops reserved:ingress)"
kubectl --context "$CTX" -n "$NS" delete ciliumnetworkpolicy grpc --wait=true

echo "== 2. grpcurl -plaintext Health/Check from the client container must fail (-max-time 10)"
denied=""
i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  out=$(grpcurl_health)
  printf '%s\n' "$out"
  if is_serving "$out"; then
    echo "(still SERVING after CNP delete, wait ${i}/8)"
    sleep 2
    continue
  fi
  denied=$out
  break
done
[ -n "$denied" ] || die "Health/Check still SERVING after CNP delete"

echo "== 3. hubble observe -P --kube-context $CTX --to-pod $NS/$pod --verdict DROPPED --last 5 -o compact"
hubble_out=""
ident_ok=0
i=0
while [ "$i" -lt 6 ]; do
  i=$((i + 1))
  hubble_out=$(hubble observe -P --kube-context "$CTX" \
    --to-pod "$NS/$pod" --verdict DROPPED --last 5 -o compact 2>&1 || true)
  printf '%s\n' "$hubble_out"
  if printf '%s' "$hubble_out" | grep -q 'Policy denied DROPPED' &&
     printf '%s' "$hubble_out" | grep -q '(ingress)'; then
    json=$(hubble observe -P --kube-context "$CTX" \
      --to-pod "$NS/$pod" --verdict DROPPED --last 5 -o json 2>&1 || true)
    ident=$(printf '%s' "$json" | python3 -c '
import json,sys
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        f=json.loads(line).get("flow") or {}
    except Exception:
        continue
    src=f.get("source") or {}
    ident=src.get("identity")
    labels=" ".join(src.get("labels") or [])
    if ident==8 or "reserved:ingress" in labels:
        print(f"source identity {ident} ({labels})")
        break
' 2>/dev/null || true)
    if [ -n "$ident" ]; then
      printf '%s\n' "$ident"
      ident_ok=1
      break
    fi
    echo "compact has Policy denied DROPPED from (ingress); identity 8 not yet in json (${i}/6)"
  else
    echo "(Hubble compact does not yet show Policy denied DROPPED from (ingress), wait ${i}/6)"
  fi
  sleep 2
done
[ "$ident_ok" = 1 ] || die "Hubble did not show Policy denied DROPPED from (ingress) identity 8"

echo "== 4. re-apply $APP"
kubectl --context "$CTX" apply -f "$APP"
trap - EXIT

echo "== 5. Health/Check SERVING again"
served=""
i=0
while [ "$i" -lt 12 ]; do
  i=$((i + 1))
  out=$(grpcurl_health)
  printf '%s\n' "$out"
  if is_serving "$out"; then
    served=$out
    break
  fi
  echo "(not SERVING after re-apply, wait ${i}/12)"
  sleep 2
done
[ -n "$served" ] || die "Health/Check not SERVING after re-apply"

echo "policy-proof: CNP grpc required; Policy denied DROPPED from (ingress) identity 8; SERVING restored"
