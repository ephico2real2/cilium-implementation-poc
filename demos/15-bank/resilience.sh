#!/usr/bin/env bash
# resilience.sh — three failure drills on the bank, each answered by the app's own responses:
#   A. payments in poc1 scaled to 0 (static, not mid-run): does the bank keep working from poc2 alone?
#   B. one of the two accounts pods killed while balance reads run: does anyone notice?
#   C. the DATABASES: postgres-0 (poc2) and redis-0 (poc1) deleted — does the data survive the pod?
# Bash on purpose (gotcha #29). Run: scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/resilience.sh
set -uo pipefail
k1() { kubectl --context kind-poc1 "$@"; }; k2() { kubectl --context kind-poc2 "$@"; }
CA="${CA:-docs/root-ca.crt}"; GW=$(k1 -n routes get gateway routes-gw -o jsonpath='{.status.addresses[0].value}')
API="https://bankapi.poc.local"; C=(--cacert "$CA" --resolve "bankapi.poc.local:443:$GW" -s --max-time 5)
field() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: print('-'); sys.exit()
v=d
for k in '$1'.split('.'): v = v.get(k, {}) if isinstance(v, dict) else {}
print(v if v not in ({}, None) else '-')"; }
bal() { curl "${C[@]}" "$API/api/balance/$1" | field balance_cents; }
hdr() { echo; echo "== $*"; }
# wait_new <kctx-fn> <pod> <old-uid>: the StatefulSet recreates the pod with the same NAME, so "Ready" must be
# checked on a pod whose UID differs from the one deleted — the first run read the old pod's status.
wait_new() { local kf=$1 pod=$2 old=$3 i; for i in $(seq 1 60); do u=$($kf -n bank get pod "$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null); r=$($kf -n bank get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null); [ -n "$u" ] && [ "$u" != "$old" ] && [ "$r" = true ] && { echo $((i*2)); return; }; sleep 2; done; echo timeout; }
# a background reader: one balance read per second for $1 seconds; prints ok/fail and the longest failure gap
reader() { local secs=$1 acc=$2; local ok=0 fail=0 gap=0 maxgap=0; local end=$((SECONDS+secs)); while [ $SECONDS -lt $end ]; do
  if [ "$(curl "${C[@]}" -o /dev/null -w '%{http_code}' "$API/api/balance/$acc")" = 200 ]; then ok=$((ok+1)); [ $gap -gt $maxgap ] && maxgap=$gap; gap=0; else fail=$((fail+1)); gap=$((gap+1)); fi; sleep 1; done
  [ $gap -gt $maxgap ] && maxgap=$gap; echo "  reader: $ok ok, $fail failed, longest outage ${maxgap}s (1 read/s over ${secs}s)"; }

hdr "A. payments in poc1 scaled to 0 — the bank must keep working from poc2 alone (no labels, no client change)"
k1 -n bank scale deploy/payments --replicas=0 >/dev/null; sleep 8
echo "  poc1's service map for payments now (only the poc2 backend may remain):"
k1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list 2>/dev/null | grep -A2 "$(k1 -n bank get svc payments -o jsonpath='{.spec.clusterIP}'):80" | sed 's/^/    /'
echo "  20 payments through the Gateway:"; demos/15-bank/exercise.sh 20 chk-1001 2>/dev/null | grep -E 'calls:|payments served by|LEDGER' | sed 's/^/  /'
k1 -n bank scale deploy/payments --replicas=1 >/dev/null; k1 -n bank rollout status deploy/payments --timeout=120s 2>&1 | tail -1 | sed 's/^/  /'

hdr "B. kill one of the two accounts pods (poc2) while balances are read once a second"
reader 25 chk-1001 & R=$!; sleep 5; V=$(k2 -n bank get pod -l app=accounts -o jsonpath='{.items[0].metadata.name}'); echo "  >>> deleting $V"; k2 -n bank delete pod "$V" --wait=false >/dev/null; wait $R
k2 -n bank rollout status deploy/accounts --timeout=120s 2>&1 | tail -1 | sed 's/^/  /'

hdr "C1. postgres-0 (poc2, PVC) deleted — the system of record goes away and comes back"
B1=$(bal chk-1001); B2=$(bal chk-1002); echo "  balances before: chk-1001=$B1 chk-1002=$B2"
PV=$(k2 -n bank get pvc data-postgres-0 -o jsonpath='{.spec.volumeName}'); echo "  PVC data-postgres-0 -> PV $PV"
OLD=$(k2 -n bank get pod postgres-0 -o jsonpath='{.metadata.uid}')
reader 60 chk-1001 & R=$!; sleep 5; echo "  >>> $(date -u +%T) deleting postgres-0 (uid ${OLD:0:8}…)"; k2 -n bank delete pod postgres-0 --wait=false >/dev/null
T_NEW=$(wait_new k2 postgres-0 "$OLD"); echo "  >>> $(date -u +%T) a NEW postgres-0 (uid $(k2 -n bank get pod postgres-0 -o jsonpath='{.metadata.uid}' | cut -c1-8)…) is Ready ~${T_NEW}s after the delete, started $(k2 -n bank get pod postgres-0 -o jsonpath='{.status.startTime}')"
wait $R
echo "  PVC data-postgres-0 -> PV $(k2 -n bank get pvc data-postgres-0 -o jsonpath='{.spec.volumeName}')  (must be the same volume)"
A1=$(bal chk-1001); A2=$(bal chk-1002); echo "  balances after : chk-1001=$A1 chk-1002=$A2  -> $([ "$A1" = "$B1" ] && [ "$A2" = "$B2" ] && echo 'DATA SURVIVED the pod' || echo 'DATA CHANGED — investigate')"

hdr "C2. redis-0 (poc1, PVC, appendonly) deleted — payment history and idempotency keys must survive"
K="res-$$-$RANDOM"; curl "${C[@]}" -o /dev/null -X POST "$API/api/pay" -H 'content-type: application/json' -d "{\"account\":\"chk-1001\",\"amount_cents\":100,\"merchant\":\"before-redis-restart\",\"key\":\"$K\"}"
N0=$(curl "${C[@]}" "$API/api/statement/chk-1001" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["statement"]["payments"]))'); echo "  payments listed before: $N0 (key $K just paid)"
OLD=$(k1 -n bank get pod redis-0 -o jsonpath='{.metadata.uid}'); echo "  >>> deleting redis-0 (uid ${OLD:0:8}…)"; k1 -n bank delete pod redis-0 --wait=false >/dev/null
T_NEW=$(wait_new k1 redis-0 "$OLD"); echo "  a NEW redis-0 is Ready ~${T_NEW}s after the delete; AOF replayed: $(k1 -n bank exec redis-0 -- redis-cli dbsize 2>/dev/null) keys"; sleep 2
N1=$(curl "${C[@]}" "$API/api/statement/chk-1001" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["statement"]["payments"]))'); echo "  payments listed after : $N1 -> $([ "$N1" = "$N0" ] && echo 'HISTORY SURVIVED' || echo 'HISTORY CHANGED')"
b=$(bal chk-1001); curl "${C[@]}" -X POST "$API/api/pay" -H 'content-type: application/json' -d "{\"account\":\"chk-1001\",\"amount_cents\":100,\"merchant\":\"before-redis-restart\",\"key\":\"$K\"}" | python3 -c "import json,sys; d=json.load(sys.stdin)['payment']; print('  replaying key $K after the restart: replay=%s' % d.get('replay'))"; echo "  balance $b -> $(bal chk-1001) (must be unchanged: the key survived in the AOF)"

hdr "what this does NOT prove"
echo "  The PVs are kind's local-path volumes: $(k2 get pv $PV -o jsonpath='{.spec.hostPath.path}') on $(k2 get pv $PV -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')."
echo "  Data survives a POD restart on the same node. It does not survive that NODE. Part 8 (dbfailover.sh) adds a hot standby in the other cluster so the database survives its CLUSTER; replicated storage or a managed database is still the production answer for the node."
