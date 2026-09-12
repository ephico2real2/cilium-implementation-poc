#!/usr/bin/env bash
# scale.sh — load balancing across BOTH clusters for a scaled-out service, watched per pod.
#   A. payments 3 replicas in EACH cluster -> poc1's map shows one pool of 6 (3 local + 3 remote)
#   B. 300 payments from 16 parallel clients (a new connection each) -> which pod answered, per pod and per cluster
#   C. live: a loop prints the spread every 5 s while payments goes 1+1 -> 3+3 -> poc2 0 -> 3+3
#   D. the same 300 through a twin Service created with service.cilium.io/lb-algorithm=maglev
# Bash on purpose. Run: scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/scale.sh
set -uo pipefail
k1() { kubectl --context kind-poc1 "$@"; }; k2() { kubectl --context kind-poc2 "$@"; }
CA="${CA:-docs/root-ca.crt}"; GW=$(k1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
API="https://bankapi.poc.local"; export CA GW API
hdr() { echo; echo "== $*"; }
short() { sed -E 's/^payments-[a-z0-9]+-//'; }
# one payment; prints "<cluster>/<pod>" or FAIL. Exported so xargs -P can call it.
one() { curl -s --max-time 6 --cacert "$CA" --resolve "bankapi.poc.local:443:$GW" -X POST "$API/api/pay" -H 'content-type: application/json' \
  -d "{\"account\":\"chk-1002\",\"amount_cents\":1,\"merchant\":\"lb\",\"key\":\"lb-$$-$1-$RANDOM\"}" \
  | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["payment"]["served_by"]; print(d["cluster"]+"/"+d["pod"])
except Exception: print("FAIL")'; }
export -f one
spread() { # $1 = how many, $2 = parallelism; prints per-pod and per-cluster counts
  seq 1 "$1" | xargs -P "$2" -I{} bash -c 'one {}' | sort | uniq -c | sort -k2 | awk '{printf "    %4d  %s\n", $1, $2}' | short
}
percluster() { seq 1 "$1" | xargs -P "$2" -I{} bash -c 'one {}' | cut -d/ -f1 | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; }
# backends of ONE service: from its frontend line up to the next service's line (grep -A8 bled into the
# next two Services in the first run and reported "9 backends" for a pool of 6 — the transcript keeps it).
svcmap() { k1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null | awk -v ip="$(k1 -n bank get svc "$1" -o jsonpath='{.spec.clusterIP}'):80/TCP" '$2==ip{p=1; print; next} p && $2!="=>" {exit} p{print}'; }
mapcount() { svcmap "$1" | grep -c '=>'; }
curl -s --cacert "$CA" --resolve "bankapi.poc.local:443:$GW" -o /dev/null -X POST "$API/api/credit/chk-1002" -H 'content-type: application/json' -d '{"amount_cents":100000}'

hdr "A. scale payments to 3 replicas in EACH cluster — one pool of 6 from poc1's point of view"
k1 -n bank scale deploy/payments --replicas=3 >/dev/null; k2 -n bank scale deploy/payments --replicas=3 >/dev/null
k1 -n bank rollout status deploy/payments --timeout=180s 2>&1 | tail -1; k2 -n bank rollout status deploy/payments --timeout=180s 2>&1 | tail -1
for i in $(seq 1 30); do [ "$(mapcount payments)" -ge 6 ] && break; sleep 2; done
echo "  poc1's eBPF service map for payments ($(mapcount payments) backends):"
svcmap payments | grep '=>' | sed 's/^ */    /' | awk '{for(i=1;i<=NF;i++) if($i=="=>") b=$(i+1); print $0, (b ~ /^10\.10\./ ? "<- poc1" : "<- poc2")}'

hdr "B. 300 payments, 16 parallel clients, a new TCP connection each — who answered"
echo "  per pod:"; spread 300 16
echo "  (Cilium picks a backend per CONNECTION at random — six pods, two clusters, one pool; expect roughly 50 each, no preference for the local cluster)"

hdr "C. live: the spread every 5 s while the deployment changes under load"
k1 -n bank scale deploy/payments --replicas=1 >/dev/null; k2 -n bank scale deploy/payments --replicas=1 >/dev/null; sleep 12
( end=$((SECONDS+60)); while [ $SECONDS -lt $end ]; do printf '  t=%2ss  %s\n' "$SECONDS" "$(percluster 40 8)"; done ) &
LOOP=$!
sleep 10; echo "  >>> scaling to 3+3"; k1 -n bank scale deploy/payments --replicas=3 >/dev/null; k2 -n bank scale deploy/payments --replicas=3 >/dev/null
sleep 20; echo "  >>> poc2 payments -> 0 (a whole cluster's share gone)"; k2 -n bank scale deploy/payments --replicas=0 >/dev/null
sleep 15; echo "  >>> poc2 back to 3"; k2 -n bank scale deploy/payments --replicas=3 >/dev/null
wait $LOOP
echo "  poc1's map now: $(mapcount payments) backends"

hdr "D. the same pool behind a twin Service created with lb-algorithm=maglev (consistent hashing; only settable at creation)"
cat <<EOF | k1 apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: payments-maglev
  namespace: bank
  annotations: {service.cilium.io/global: "true", service.cilium.io/lb-algorithm: maglev}
spec: {selector: {app: payments}, ports: [{port: 80, targetPort: 8080}]}
EOF
cat <<EOF | k2 apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: payments-maglev
  namespace: bank
  annotations: {service.cilium.io/global: "true", service.cilium.io/lb-algorithm: maglev}
spec: {selector: {app: payments}, ports: [{port: 80, targetPort: 8080}]}
EOF
sleep 8; echo "  poc1's map for payments-maglev: $(mapcount payments-maglev) backends; algorithm as Cilium sees it:"
svcmap payments-maglev | sed 's/^ */    /'
# Proof the algorithm differs: only Maglev services get a lookup table in the BPF map cilium_lb4_maglev.
# Its keys are the 16-bit service ids in NETWORK byte order (id 56 -> 0x0038 -> stored 0x3800 = 14336).
maglev_has() { local id=$1 key=$(( (id % 256) * 256 + id / 256 )); k1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg map get cilium_lb4_maglev 2>/dev/null | awk -v k="$key" '$1==k{f=1} END{print (f?"YES":"no")}'; }
for svc in payments payments-maglev; do id=$(svcmap $svc | head -1 | awk '{print $1}'); printf '    %-16s service id %-3s  Maglev table in cilium_lb4_maglev: %s\n' "$svc" "$id" "$(maglev_has $id)"; done
echo "  300 payments through api, api pointed at payments-maglev for this run (env swap, rollout, then back):"
k1 -n bank set env deploy/api PAYMENTS_URL=http://payments-maglev.bank.svc.cluster.local >/dev/null; k1 -n bank rollout status deploy/api --timeout=120s >/dev/null 2>&1
spread 300 16
k1 -n bank set env deploy/api PAYMENTS_URL- >/dev/null; k1 -n bank rollout status deploy/api --timeout=120s >/dev/null 2>&1
echo "  (Maglev hashes the 5-tuple onto a table of the same 6 backends: spread is still even; its property is that a backend's loss moves only that backend's flows — at most 1% of the rest, per the docs)"

hdr "back to 1+1"
k1 -n bank scale deploy/payments --replicas=1 >/dev/null; k2 -n bank scale deploy/payments --replicas=1 >/dev/null; k1 -n bank rollout status deploy/payments --timeout=120s 2>&1 | tail -1
